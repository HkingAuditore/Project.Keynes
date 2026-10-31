extends SceneTree
## Plan §18.1 evidence row (`docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md:1526`):
##
##     "pending 保留旧贡献，拒绝无残留，一次性效果不重放。"
##     (while pending the OLD contribution is kept; a rejection leaves no
##      residue; a one-shot effect is not replayed)
##
## The sibling fixture `ideology_save_transaction_states_test.gd` already owns the
## SAVE/RESTORE half of this row (pending / ACK-success / ACK-rejected survive a
## PKEF+PKID round trip, and the one-shot count is 0 on both sides). The checklist
## row `...plan-v3.md:1591` records exactly what is still missing:
##
##     "SV2 314/0 covers pending / ACK success / ACK rejected, one-shot count 0
##      on both sides -- **the numeric side of 'keeps the old contribution' is
##      NOT asserted**".
##
## This fixture is that numeric side, on ONE live timeline (no save/restore).
##
## ---------------------------------------------------------------------------
## PLAN §9.3 -- A SETTLE ON DAY D PUBLISHES ITS BASIS NO EARLIER THAN D+1
## ---------------------------------------------------------------------------
##
## The runtime now implements plan §9.3: a structural change that receives its
## required real ACK on business day D is a confirmed projection with
##
##     derived_basis_confirmed_day  = D
##     derived_basis_eligible_day   = D + 1
##
## and `step_derived_rebuild` returns early (REFUSING to adopt, keeping the
## previously installed front) whenever `day < eligible_from_day`
## (`ideology_runtime.cpp:7040-7048`). `get_ideology_report()` exports all three
## numbers, including `derived_rebuild_gated_by_eligibility` -- the count of
## refusals, which is what distinguishes "the gate held" from "nothing tried".
##
## Consequence for this fixture, and the reason every phase below is three days
## longer than it looks: a card that settles on D contributes NOTHING on D. The
## front it had before the settle is the one a reader sees on D. Only D+1 carries
## the new basis. So this fixture asserts, after EVERY settle:
##
##     eligible_day == confirmed_day + 1        (the lag is real, not a rounding)
##     confirmed_day == the settle day          (dated to the ACK, not the submit)
##     gated_by_eligibility increased           (the refusal actually happened)
##     layer_generation == the pre-settle value (the front was NOT replaced)
##     the per-cell magnitudes are still the OLD level's
##
## and then reads the new basis on the following day. That makes this file the
## primary witness for §9.3 rather than merely a fixture that tolerates it.
##
## Note on the section below: the §10.1 half of the same promise ("an unconfirmed
## card contributes the OLD level, an unconfirmed EQUIP contributes nothing") has
## ALSO landed (`collect_effect_activations`, `ideology_runtime.cpp:2291-2321`), so
## A1 below measures branch OUTCOME A and the C1 block records that flip. The two
## sections are complementary: §10.1 decides WHICH level a pending card serves,
## §9.3 decides WHEN the settled basis may be published at all.
##
## The business days come from ONE monotonic counter (`_day` / `_tick`), never from
## literals: a settle inserts a day, so hand-numbered literals drift without any
## visible error. `_run_one_ideology_day` is only ever called through `_tick`.
##
## ---------------------------------------------------------------------------
## THE DOCUMENTED RUNTIME GAP THIS FIXTURE MEASURES
## ---------------------------------------------------------------------------
##
## `collect_effect_activations` gates a card's derived contribution on exactly two
## facts (`ideology_runtime.cpp:2285`):
##
##     if (state.location == INACTIVE || state.level < 0) return true;
##
## It never reads `state.transition.active`. But `start_transition` writes the
## TARGET state at REQUEST time, before any Effect transaction exists:
##
##     ideology_runtime.cpp:3596-3599
##         set_state_location(country, idea_slot, location);
##         state.slot_index = slot_index;
##         state.level = level;          <-- the NEW level, at request time
##         ++state.generation;
##
## and `poll_pending_transition` only re-writes `state.level` on FAILURE
## (`:3765`, `state.level = state.transition.previous_level`); on success the new
## level is already there. So between the request and the ACK the runtime holds
## the NEW level, and the layer rebuild (`step_derived_rebuild`, `:5049`) reads it.
##
## The same function already knows better for a neighbouring quantity: the daily
## understanding accrual one screen below picks
##
##     ideology_runtime.cpp:5006-5007
##         const int32_t growth_level = state->transition.active != 0
##             ? state->transition.previous_level : state->level;
##
## i.e. it deliberately keeps the OLD level while a transition is in flight, while
## the effect activation path does not. That is the inconsistency.
##
## So this fixture does NOT decide the answer in advance. It measures the pending
## per-cell values and then records which of the two possible worlds it found:
##
##     Outcome A -- the pending card contributes the OLD (L1) magnitudes: the
##                  plan's promise holds and the check is asserted as written.
##     Outcome B -- the pending card already contributes the NEW (L2) magnitudes:
##                  a REAL GAP, reported as a `[FINDING]` line with the measured
##                  numbers. The plan's promise is then NOT asserted (it would
##                  either make the fixture lie or make it red for a known
##                  reason); instead the strongest invariant that holds either way
##                  is asserted -- the pending value must be EXACTLY one of the two
##                  authored magnitudes, never a third value and never nothing --
##                  and the fixture pins the branch it measured.
##
## The header of the run says which branch was taken. A future fix flips the
## `[FINDING]` line to `[OK]` instead of breaking the fixture.
##
## ---------------------------------------------------------------------------
## THE EXPERIMENT: A LEVEL-UP, WHICH IS THE SHARPEST FORM OF THE QUESTION
## ---------------------------------------------------------------------------
##
## `idea.public_hygiene` is a permanent cell card (kind 12 = OWN_TERRITORY) whose
## two per-level magnitudes are authored and different:
##
##   L1  birth factor +3277/Q16 = 0.05000305, housing cut -5243/Q16
##       (`data/ideologies/default_ideology_effects.tres:5336-5401`)
##   L2  birth factor +5243/Q16 = 0.08000183, housing cut -6554/Q16
##       (`data/ideologies/default_ideology_effects.tres:5403-5468`)
##   L2 threshold 524288 Q16 (`data/ideologies/default_ideology_catalog.tres:5331`)
##
## A level is the highest catalog row whose `understanding_threshold_q16` is
## <= `understanding_q16` (`unlocked_level`, `:1638-1647`). `ADD_UNDERSTANDING`
## adds the value and immediately asks for the next level transition
## (`:4847-4857`). So submitting 524288 while the card sits settled at L1 starts a
## L0->L1 (row 0 -> row 1) transition on the NEXT `run_ideology_daily` slice, and
## the interesting window is the moment that day's slice ends: `state.level` is the
## new row, the Effect transaction is still unACKed, and the derived front has been
## rebuilt for the day.
##
## ---------------------------------------------------------------------------
## THE HANDSHAKE (measured, not optional)
## ---------------------------------------------------------------------------
##
## A transition only becomes pending when `start_transition` enqueued at least one
## Effect batch (`:3675-3726`), and it only settles when the Effect adapters ACK
## those batches. The production order is mandatory
## (`world_ext_bind_methods.cpp:635-648`):
##
##     dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                        ->  ack_effect_native_modifier()
##
## `run_modifier_daily` between dispatch and ACK is what completes the rows the
## dispatch submitted; without it the ACK keeps reporting `pending` and
## `pending_transition_count` never returns to 0.
##
## ---------------------------------------------------------------------------
## "REJECTION LEAVES NO RESIDUE" -- WHICH REJECTION, AND WHY
## ---------------------------------------------------------------------------
##
## `ack_effect_transactions` cannot produce a rejection: a bad mask only bumps a
## counter (`effect_runtime.cpp:6744-6782`). A rejected row comes from a domain ACK
## (`:5824-5832` modifier, `:5995-6004` country, `:6183-6194` economy) or from
## instance-generation supersession (`:2536-2547`). Supersession needs control over
## an Effect INSTANCE, which an ideology transition does not expose, so this
## fixture uses the DOMAIN-ACK path -- the one the plan's own ownership table
## assigns to the Effect domain (`...plan-v3.md:242`).
##
## `ack_native_modifier` marks a transaction REJECTED when the Modifier runtime's
## `command_result_pod` answers `ok = false` (`effect_runtime.cpp:5801-5813`,
## `:5824-5832`). The Modifier runtime does that for a definition it does not know:
##
##     modifier_runtime.cpp:997-1000
##         if (command.definition_id < 0 ...) {
##             result = {false, "modifier_definition_unknown", 0, day};
##
## So worlds "B" and "C" inject ONE extra on-enter row naming a definition key the
## Modifier catalog does not contain. The row is emitted into the transition's
## APPLY batch (on-enter rows are events, so `emit_templates` never skips them --
## `ideology_runtime.cpp:1684-1694`), the modifier ACK rejects the batch, and
## `poll_pending_transition` sees `EffectRuntime::REJECTED`, rolls the card back
## and writes a `RECEIPT_REJECTED` with reason
## `ideology_effect_transition_rejected` (`:3744-3779`).
##
## B and C differ in WHICH batch carries the probe, and that is the whole point:
##
##   world B  the poison rides in the LEVEL-UP batch. Measured: the rollback
##            happens and the receipt is written, but the SAME slice retries the
##            intent (slice order is poll -> commands -> active progress,
##            `:4918-5035`, `:5022`), and the retry re-writes `state.level` to the
##            target at request time. So between two rollbacks the front NEVER
##            shows the reverted values. B therefore measures "no residue" as NO
##            ACCUMULATION across two reject/retry cycles, and reports the retry
##            as a `[FINDING]`.
##
##   world C  the poison rides in the EQUIP batch (`equip` enters the card's
##            current level via `unentered_level_mask`, `:4566-4569`). Nothing
##            periodic re-issues an equip, so the rolled-back front IS observable:
##            the card goes back to INACTIVE and its contribution goes back to the
##            pre-transition value of ZERO rows, and stays there.
##
## A SECOND FINDING, measured in both worlds and reported instead of asserted away:
## "no residue" holds for the DERIVED cell layer and for the ideology state, but
## NOT for the Modifier domain. `run_modifier_daily` applies each row of the batch
## in submission order and only afterwards does `ack_effect_native_modifier` reach
## the failing row and mark the transaction REJECTED (`effect_runtime.cpp:5801-5832`);
## `apply_rejected_instance_transition` does not reverse rows that already
## committed. The fixture therefore asserts the precise, confined shape of that
## residue (only rows from the batch the rejection killed) and prints a
## `[FINDING]` naming it -- including that a rejected batch still EXECUTES the
## one-shot rows that preceded its failing row.
##
## ---------------------------------------------------------------------------
## "A ONE-SHOT EFFECT IS NOT REPLAYED" -- THE EXACT COUNT
## ---------------------------------------------------------------------------
##
## A level's `on_enter_effects` are emitted exactly once per entered level:
## `entered_on_success` carries `1 << level` only when
## `state.entered_levels` does not already hold that bit (`:3822-3823`), the
## emission happens at REQUEST time inside the pending batch (`:3660-3669`), and
## settlement only ORs `state.entered_levels |= transition.entered_on_success`
## (`:3783`) -- it never re-emits.
##
## The SHIPPED `idea.public_hygiene` L2 has an empty on-enter list
## (`default_ideology_catalog.tres:5334`), so world "A" adds one on-enter row to
## that Level RESOURCE before the catalog is compiled -- the same resource-
## configuration technique `ideology_save_transaction_states_test.gd` uses for its
## structural probe and `ideology_mechanism_equip_level_test.gd` uses to empty the
## synergy table. It names the real Modifier definition `ideology.standardization`
## (domain 1 = COUNTRY), which the Modifier runtime resolves, so the batch still
## ACKs normally; `command_key` is a fixture-unique `ideology.once_marker` so the
## emitted row is unambiguous.
##
##   `EffectDomainCatalog._ideology_command_definition`
##   (`scripts/effect/effect_domain_catalog.gd:875-920`) compiles a matching Effect
##   command definition for every ideology on-enter row, and
##   `enqueue_external_effect_batch_pod` (`effect_runtime.cpp:3484-3521`) refuses a
##   batch whose row has no compiled definition. Injecting the row on the RESOURCE
##   before `compile_native_catalog` is therefore what makes it emittable at all --
##   patching the compiled Dictionary afterwards would silently do nothing.
##
## The count is read from `poll_effect_transactions`, which returns the in-flight
## rows with both `command_keys` and `command_definition_keys`
## (`effect_runtime.cpp:6610-6629`) as long as no native adapter has claimed the
## transaction yet (`:6583-6595`). So:
##
##   before the level-up            0 emitted rows
##   while pending                  1 emitted row (inside the unACKed batch)
##   after the handshake            0 in flight (consumed by the ACK)
##   two further ideology days      0 -- the total across the boundary is 1
##
## The strongest available count is the Modifier store itself: the applied row is a
## permanent COUNTRY-domain row for `ideology.standardization`, so
## `list_modifiers(1, country, "")` must hold EXACTLY ONE such row after the
## settle and still exactly one two days later. Emission count and applied count
## therefore agree, and both are 1.
##
## ---------------------------------------------------------------------------
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_pending_keeps_old_contribution_test.gd
##
## Nothing is relaxed: no C++ change, no DLL swap, no worker, no bypass. The call
## set is the main-thread production set.

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
## (`data/ideologies/default_ideology_catalog.tres:5331`).
const L2_THRESHOLD_Q16 := 524288
## `LevelPublicHygieneL3.understanding_threshold_q16`: far above what this fixture
## reaches, so the card cannot advance twice and confuse the one-shot count.
const L3_THRESHOLD_Q16 := 1572864
## The AUTHORED per-level magnitudes, quoted from the shipped content so the
## runtime's own interpretation can be checked against the data:
##
##   public_hygiene_l1  birth factor +3277/65536, housing cut -5243/65536
##   public_hygiene_l2  birth factor +5243/65536, housing cut -6554/65536
##
## The `.cut` row is authored as a POSITIVE magnitude on a `.cut` stat key and the
## sign comes from the definition, which is why the derived delta is negative.
const L1_ADD_Q16 := 3277
const L1_CUT_Q16 := 5243
const L2_ADD_Q16 := 5243
const L2_CUT_Q16 := 6554

## The synthesized on-enter one-shot (see the header). `ideology.standardization`
## is a real COUNTRY-domain Modifier definition, so the Modifier runtime resolves
## it and the transition still ACKs cleanly; the distinct command key is what makes
## the emitted row identifiable in `poll_effect_transactions`.
const ONESHOT_COMMAND_KEY := "ideology.once_marker"
const ONESHOT_DEFINITION_KEY := "ideology.standardization"
const ONESHOT_VALUE_Q16 := 65536
## World B's poisoned row: a definition key the Modifier catalog does not contain,
## which is what turns the domain ACK into a rejection.
const POISON_COMMAND_KEY := "ideology.poison_marker"
const POISON_DEFINITION_KEY := "test.reject_probe.unknown_modifier"
## The card's own COUNTRY-domain cost definition (every level row carries one:
## `EffectPublicHygieneCostL1/L2`, `default_ideology_catalog.tres:5272-5314`). Used
## only to attribute the residue this fixture measures in the Modifier store.
const COST_DEFINITION_KEY := "ideology.public_hygiene"

## Opcodes out of `ideology_runtime.h:66-79`.
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8
## `ReceiptStatus` (`ideology_runtime.h:81-85`).
const RECEIPT_REJECTED := 3
## `Location` (`ideology_runtime.h:80`).
const LOCATION_INACTIVE := 0
const LOCATION_IDEOLOGY := 1
## `EffectRuntime` transaction status codes: 1 PLANNED, 2 PREFLIGHTED,
## 3 COMMITTED, 4 ACKED, 5 REJECTED.
const TX_REJECTED := 5
## `poll_pending_transition`'s refusal text when an Effect transaction of the
## transition did not ACK (`ideology_runtime.cpp:3753`).
const REASON_TRANSITION_REJECTED := "ideology_effect_transition_rejected"

## Population per cell: `household_farmer` (political class "farmer", adopt and
## repeal stance +8192 for this card) 3x `subsistence_farmer` (class "general",
## repeal stance -8192). `idea.public_hygiene` has `repeal_threshold_q16 = 0`
## (`default_ideology_catalog.tres:5409`), so a general-only population measures a
## NEGATIVE repeal support and every equip is refused with
## `ideology_support_threshold_not_met`. The farmer majority is what keeps the
## adopt gate positive without any fixture-side bypass.
const POP_FARMER := 60
const POP_GENERAL := 20
## `evaluate_effect_program_magnitude` takes a fixed metric vector; the two
## programs read none of it.
const METRIC_SLOTS := 120
const MAX_SLICES := 512
## Class-opinion direction 1 = REPEAL (`ideology_runtime.h`), used only for a log
## line.
const SUPPORT_REPEAL_INDEX := 1

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

var _checks := 0
var _failures := 0
var _seq := 0
## The fixture's business-day counter.
##
## Plan §9.3 makes the business day a LOAD-BEARING quantity: a structural change
## confirmed on day D is published by the derived layer no earlier than D+1, so an
## extra settle day shifts every later day of a phase. Hand-numbered literals are
## exactly what let this fixture read the settle day when the content it wanted had
## moved one day later, so every day below is derived from these two numbers:
##
##   `_day`      the day the NEXT pass will run -- a command submitted for "now"
##               uses this value, so its `effective_day` always lands on the pass
##               that measures it (`ideology_runtime.cpp:4980`)
##   `_ran_day`  the day the LAST pass ran -- the adapter handshake is driven on it,
##               so the Effect/Modifier domains share the ideology clock
var _day := 0
var _ran_day := -1
## The level-up magnitudes, resolved once per catalog from the interpreter.
var _l1_add := 0.0
var _l1_cut := 0.0
var _l2_add := 0.0
var _l2_cut := 0.0
## Which branch the pending measurement landed on ("OLD" / "NEW" / "OTHER").
var _pending_branch := "UNMEASURED"
var _summary: Array = []


func _init() -> void:
	_run()


func _run() -> void:
	print("[PK] ==================================================================")
	print("[PK] ideology §18.1: pending keeps the old contribution / rejection "
		+ "leaves no residue / one-shot not replayed")
	print("[PK] ==================================================================")

	# World A compiles first, from the shipped catalog plus the ONE on-enter
	# one-shot this fixture injects. Compiling happens per world because each
	# later world appends another on-enter row, and the effect catalog carries the
	# corresponding command definition.
	var catalogs_a: Dictionary = _compile_catalogs("A", -1)
	if catalogs_a.is_empty():
		_finish()
		return
	var dense: int = catalogs_a["dense"]
	_phase_a_pending_numeric(catalogs_a, dense)

	# World B: the rejection probe rides in the LEVEL-UP batch.
	var catalogs_b: Dictionary = _compile_catalogs("B", 1)
	if catalogs_b.is_empty():
		_finish()
		return
	_phase_b_rejection_no_residue(catalogs_b, dense)

	# World C: the rejection probe rides in the EQUIP batch, where nothing retries
	# the intent, so the rolled-back front is observable directly.
	var catalogs_c: Dictionary = _compile_catalogs("C", 0)
	if catalogs_c.is_empty():
		_finish()
		return
	_phase_c_rejected_equip_no_residue(catalogs_c, dense)
	_finish()


# =========================================================================
# world A: the numeric side of "pending keeps the old contribution"
# =========================================================================

func _phase_a_pending_numeric(catalogs: Dictionary, dense: int) -> void:
	print("[PK] ---------- world A: level-up while the transition is pending "
		+ "----------")
	var world: Dictionary = _new_world(catalogs, "A")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var owned: int = int(world["owned"])
	# One equipped level row writes one contribution per (stat, cell).
	var card_rows: int = 2 * owned
	_l1_add = _program_magnitude(ext, PROGRAM_L1, "L1")
	_l1_cut = -float(L1_CUT_Q16) / float(Q16_ONE)
	_l2_add = _program_magnitude(ext, PROGRAM_L2, "L2")
	_l2_cut = -float(L2_CUT_Q16) / float(Q16_ONE)

	# ---- A0: equip, settle at L1, then wait out the §9.3 eligibility day ----
	#
	# Plan §9.3 (docs/plans/ideology-review/22-cell-program-cap-removal-plan-v3.md):
	# a structural change that receives its required real ACK on business day D is a
	# confirmed projection whose `eligible_from_day` is D+1, and a new economy
	# freeze boundary at `sample_day = S` may only adopt the newest confirmed
	# projection that satisfies `eligible_from_day <= S`. In other words a settle on
	# D publishes its derived basis no earlier than D+1, so a card needs THREE days
	# before it has a contribution at all:
	#
	#   D      the equip command is applied; the transition is PENDING, and an
	#          unconfirmed equip contributes NOTHING (plan §10.1), so the front is
	#          still the empty one
	#   D+1    the ACK has landed: the transition SETTLES, `confirmed_day = D`,
	#          `eligible_from_day = D+1`, and `step_derived_rebuild` REFUSES to
	#          adopt -- the previously installed (empty) front stays
	#   D+2    eligible: the rebuild adopts the L1 basis  <-- A0 is read HERE
	#
	# The days come from the `_day`/`_tick` counter, not from literals: one extra
	# settle day shifts every later day of the phase, which is exactly the class of
	# mistake that made this fixture read a day early.
	print("[PK] ---- A0: equip, settle, and establish the L1 baseline ----")
	_submit(ext, OP_GRANT, _day, -1, 64 * Q16_ONE, handle, "A/grant")
	_submit(ext, OP_DISCOVER, _day, dense, 0, handle, "A/discover")
	_submit(ext, OP_EQUIP, _day, dense, 0, handle, "A/equip")
	_tick(ext, "A/equip")
	var served := _serve(ext, "A/equip", true)
	_expect("A0 equip settle: the native adapters ACKED the equip's commands",
		bool(served.get("modifier_ok", false))
			and int(served.get("modifier_rejected", -1)) == 0, str(served))
	# Captured BEFORE the settle day, so the §9.3 checks below can prove the settle
	# day changed NOTHING observable instead of merely claiming it.
	var settle_gen_before := int(ext.get_derived_cell_layer_report().get(
		"layer_generation", -1))
	var gated_before := int(ext.get_ideology_report().get(
		"derived_rebuild_gated_by_eligibility", -1))
	_tick(ext, "A/equip-settle")
	var settle_day_a := _ran_day

	# ---- A0-§9.3: the settle day CONFIRMS the basis and REFUSES to adopt it ----
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	_print_state("A0 the settle day (basis confirmed, NOT adopted)",
		snap, layer, report)
	var confirmed_a := int(report.get("derived_basis_confirmed_day", -2))
	var eligible_a := int(report.get("derived_basis_eligible_day", -3))
	var gated_a := int(report.get("derived_rebuild_gated_by_eligibility", -1))
	print("[PK] A0 §9.3: settle day=%d confirmed_day=%d eligible_day=%d "
		% [settle_day_a, confirmed_a, eligible_a]
		+ "rebuild_attempts_gated=%d" % gated_a)
	_expect("§9.3: the basis is confirmed on the settle day but only eligible the "
		+ "next day", eligible_a == confirmed_a + 1,
		"confirmed=%s eligible=%s" % [str(confirmed_a), str(eligible_a)])
	_expect("§9.3: the confirmation is dated to the business day the ACK was "
		+ "observed (%d), not to the day the command was submitted" % settle_day_a,
		confirmed_a == settle_day_a,
		"confirmed=%d settle_day=%d" % [confirmed_a, settle_day_a])
	_expect("§9.3: adoption was actually refused once (the gate fired, it is not "
		+ "dead)", gated_a > gated_before,
		"gated %d -> %d" % [gated_before, gated_a])
	_expect("§9.3: on the settle day the front is NOT yet the new basis -- the "
		+ "layer generation is still the one installed before the settle",
		int(layer.get("layer_generation", -1)) == settle_gen_before,
		"generation %d -> %s (installed=%s cells=%s)" % [settle_gen_before,
			str(layer.get("layer_generation", "?")),
			str(layer.get("installed", "?")), str(layer.get("cell_count", "?"))])
	_expect("§9.3: on the settle day no cell carries the L1 contribution yet (the "
		+ "front the gate kept was the EMPTY one)",
		_present_count(ext, STAT_ADD) == 0 and _present_count(ext, STAT_CUT) == 0,
		"add_present=%d cut_present=%d" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])

	# ---- A0: the ELIGIBLE day, where the L1 baseline becomes real ---------
	_tick(ext, "A/basis-eligible")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("A0 settled at L1 (basis eligible on day %d)" % _ran_day,
		snap, layer, report)
	_expect("A0: the card is settled at level 0 (row L1) in the IDEOLOGY slot",
		int(report.get("pending_transitions", -1)) == 0
			and snap.get("locations", PackedInt32Array())
				== PackedInt32Array([LOCATION_IDEOLOGY])
			and snap.get("levels", PackedInt32Array()) == PackedInt32Array([0]),
		"pending=%s locations=%s levels=%s" % [
			str(report.get("pending_transitions", "?")),
			str(snap.get("locations", "?")), str(snap.get("levels", "?"))])
	var l1_add_cell := _covered_add(ext, STAT_ADD)
	var l1_cut_cell := _covered_add(ext, STAT_CUT)
	print("[PK] A0 magnitudes: add=%.8f cut=%.8f (L1 authored %d/%d Q16)"
		% [l1_add_cell, l1_cut_cell, L1_ADD_Q16, L1_CUT_Q16])
	_expect("A0: the settled card contributes the AUTHORED L1 add (+%d/Q16 = "
		% L1_ADD_Q16 + "%.8f)" % (float(L1_ADD_Q16) / float(Q16_ONE)),
		absf(l1_add_cell - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6,
		"derived=%.8f authored=%.8f" % [l1_add_cell,
			float(L1_ADD_Q16) / float(Q16_ONE)])
	_expect("A0: the settled card contributes the AUTHORED L1 .cut (-%d/Q16 = "
		% L1_CUT_Q16 + "%.8f)" % (-float(L1_CUT_Q16) / float(Q16_ONE)),
		absf(l1_cut_cell - (-float(L1_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"derived=%.8f authored=%.8f" % [l1_cut_cell,
			-float(L1_CUT_Q16) / float(Q16_ONE)])
	var rows_before := _front_contributions(layer)
	var cells_before := int(layer.get("cell_count", -1))
	var gen_before := int(layer.get("layer_generation", -1))
	_expect("A0: the front carries exactly the card's %d rows before the level "
		% card_rows + "change (2 stats x %d owned cells)" % owned,
		cells_before == card_rows and rows_before == card_rows,
		"cells=%d contributions=%d expected=%d" % [cells_before, rows_before,
			card_rows])
	_expect("A0: no unowned cell carries a derived contribution",
		_no_unowned_present(ext, STAT_ADD, world["owned_cells"])
			and _no_unowned_present(ext, STAT_CUT, world["owned_cells"]),
		"add_present=%d cut_present=%d" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])
	# The one-shot baseline: nothing has been emitted yet.
	var oneshot_before := _count_oneshot_rows(ext)
	print("[PK] A0 one-shot: emitted rows in flight = %d (must be 0)"
		% oneshot_before)
	_expect("A0: the level-2 on-enter one-shot has NOT been emitted before the "
		+ "level change", oneshot_before == 0, "rows=%d" % oneshot_before)
	_summary.append("A baseline: L1 add=%.8f cut=%.8f, front %d rows"
		% [l1_add_cell, l1_cut_cell, rows_before])

	# ---- A1: the level-up, measured BEFORE any ACK ------------- ----------
	print("[PK] ---- A1: ADD_UNDERSTANDING %d, measured while PENDING ----"
		% L2_THRESHOLD_Q16)
	var understanding_before := int((snap.get("understanding_q16",
		PackedInt64Array()) as PackedInt64Array)[0])
	_expect("A1: before the change the understanding is below the level-1 "
		+ "threshold (%d)" % L2_THRESHOLD_Q16,
		understanding_before < L2_THRESHOLD_Q16,
		"%d < %d" % [understanding_before, L2_THRESHOLD_Q16])
	_submit(ext, OP_ADD_UNDERSTANDING, _day, dense, L2_THRESHOLD_Q16, handle,
		"A/understanding")
	_tick(ext, "A/level")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("A1 level-up (PENDING, pre-ACK)", snap, layer, report)
	var understanding_after := int((snap.get("understanding_q16",
		PackedInt64Array()) as PackedInt64Array)[0])
	_expect("A1: the level-up really is IN FLIGHT (pending_transitions == 1); "
		+ "nothing below is measured after the ACK",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	var tx_statuses: PackedInt32Array = snap.get(
		"transition_transaction_statuses", PackedInt32Array())
	print("[PK] A1 transition transactions: ids=%s statuses=%s (1 PLANNED, "
		% [str(snap.get("transition_transaction_ids", "?")), str(tx_statuses)]
		+ "2 PREFLIGHTED, 3 COMMITTED, 4 ACKED, 5 REJECTED)")
	_expect("A1: the card's state has ALREADY moved to the target level while "
		+ "the transition is pending (start_transition writes state.level at "
		+ "request time, ideology_runtime.cpp:3598)",
		snap.get("levels", PackedInt32Array()) == PackedInt32Array([1]),
		"levels=%s understanding=%d -> %d" % [
			str(snap.get("levels", "?")), understanding_before,
			understanding_after])
	_expect("A1: the transition carries at least one unACKed Effect transaction",
		tx_statuses.size() >= 1 and not tx_statuses.has(4),
		"statuses=%s" % str(tx_statuses))

	# ---- A1-numeric: THE HEADLINE MEASUREMENT ---------------------------
	var pending_add := _covered_add(ext, STAT_ADD)
	var pending_cut := _covered_add(ext, STAT_CUT)
	var pending_rows := _front_contributions(layer)
	var pending_cells := int(layer.get("cell_count", -1))
	var pending_present := _present_count(ext, STAT_ADD)
	var pending_present_cut := _present_count(ext, STAT_CUT)
	print("[PK] A1 PENDING per-cell: add=%.8f cut=%.8f  (L1 %.8f / %.8f, "
		% [pending_add, pending_cut, l1_add_cell, l1_cut_cell]
		+ "L2 %.8f / %.8f)" % [float(L2_ADD_Q16) / float(Q16_ONE),
			-float(L2_CUT_Q16) / float(Q16_ONE)])
	print("[PK] A1 PENDING front: installed=%s cells=%d contributions=%d "
		% [str(layer.get("installed", "?")), pending_cells, pending_rows]
		+ "(before the change: cells=%d contributions=%d)"
		% [cells_before, rows_before])
	print("[PK] A1 PENDING coverage: add present on %d of %d cells, .cut on %d"
		% [pending_present, CELLS, pending_present_cut])

	_pending_branch = _classify(pending_add, pending_cut,
		float(L1_ADD_Q16) / float(Q16_ONE), -float(L1_CUT_Q16) / float(Q16_ONE),
		float(L2_ADD_Q16) / float(Q16_ONE), -float(L2_CUT_Q16) / float(Q16_ONE))
	print("[PK] A1 PENDING OUTCOME = %s" % _pending_branch)
	if _pending_branch == "OLD":
		print("[PK] [OK] pending keeps the OLD contribution: the card is still "
			+ "serving the L1 magnitudes while its transition is unACKed.")
	elif _pending_branch == "NEW":
		print("[PK] [FINDING] pending does NOT keep the old contribution. "
			+ "MEASURED while pending_transitions=1: per-cell add=%.8f cut=%.8f, "
			% [pending_add, pending_cut]
			+ "which are exactly the L2 magnitudes (+%d/Q16 = %.8f, -%d/Q16 = "
			% [L2_ADD_Q16, float(L2_ADD_Q16) / float(Q16_ONE), L2_CUT_Q16]
			+ "%.8f), NOT the L1 ones (+%d/Q16 = %.8f, -%d/Q16 = %.8f). "
			% [-float(L2_CUT_Q16) / float(Q16_ONE), L1_ADD_Q16,
				float(L1_ADD_Q16) / float(Q16_ONE), L1_CUT_Q16,
				-float(L1_CUT_Q16) / float(Q16_ONE)]
			+ "Root cause: collect_effect_activations gates only on "
			+ "state.location != INACTIVE && state.level >= 0 "
			+ "(ideology_runtime.cpp:2285) and never reads transition.active, "
			+ "while start_transition already wrote state.level = target at "
			+ "request time (:3598). The daily understanding accrual right next "
			+ "door DOES read transition.active and keeps previous_level (:5006), "
			+ "so the two halves of the same card disagree. The plan's promise "
			+ "(...plan-v3.md:1526) is therefore NOT asserted as written.")
	else:
		print("[PK] [FINDING] pending carries NEITHER authored level: add=%.8f "
			% pending_add + "cut=%.8f -- unexpected third value." % pending_cut)
	# The invariant that MUST hold in every world: the pending value is exactly
	# one of the two authored magnitudes. Never a third value, never nothing.
	_expect("A1 [invariant]: the pending per-cell add is EXACTLY one of the "
		+ "card's two authored level magnitudes (never a third value, never "
		+ "zero) -- measured branch=%s" % _pending_branch,
		_pending_branch != "OTHER",
		"pending=%.8f L1=%.8f L2=%.8f" % [pending_add,
			float(L1_ADD_Q16) / float(Q16_ONE),
			float(L2_ADD_Q16) / float(Q16_ONE)])
	if _pending_branch == "NEW":
		# The measured branch is pinned precisely, but the plan's promise is not.
		_expect("A1 [measured, OUTCOME B]: while PENDING the covered cell carries "
			+ "the L2 add (+%d/Q16) and NOT the L1 one" % L2_ADD_Q16,
			absf(pending_add - float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6
				and absf(pending_add - float(L1_ADD_Q16) / float(Q16_ONE)) > 0.02,
			"pending=%.8f L2=%.8f L1=%.8f" % [pending_add,
				float(L2_ADD_Q16) / float(Q16_ONE),
				float(L1_ADD_Q16) / float(Q16_ONE)])
		_expect("A1 [measured, OUTCOME B]: while PENDING the covered cell carries "
			+ "the L2 .cut (-%d/Q16) and NOT the L1 one" % L2_CUT_Q16,
			absf(pending_cut - (-float(L2_CUT_Q16) / float(Q16_ONE))) <= 1e-6
				and absf(pending_cut - (-float(L1_CUT_Q16) / float(Q16_ONE))) > 2e-3,
			"pending=%.8f L2=%.8f L1=%.8f" % [pending_cut,
				-float(L2_CUT_Q16) / float(Q16_ONE),
				-float(L1_CUT_Q16) / float(Q16_ONE)])
	elif _pending_branch == "OLD":
		_expect("A1 [measured, OUTCOME A]: while PENDING the covered cell still "
			+ "carries the L1 add (+%d/Q16) and not the L2 one" % L1_ADD_Q16,
			absf(pending_add - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
				and absf(pending_add - float(L2_ADD_Q16) / float(Q16_ONE)) > 0.02,
			"pending=%.8f L1=%.8f L2=%.8f" % [pending_add,
				float(L1_ADD_Q16) / float(Q16_ONE),
				float(L2_ADD_Q16) / float(Q16_ONE)])
	# Shape invariants: a pending card is still ONE card. It must not double its
	# rows and must not orphan any.
	_expect("A1: the pending card does not DOUBLE its rows -- the front still "
		+ "holds exactly %d contributions" % card_rows,
		pending_rows == card_rows and pending_cells == card_rows,
		"cells=%d contributions=%d expected=%d" % [pending_cells, pending_rows,
			card_rows])
	_expect("A1: the pending card does not ORPHAN any contribution -- no unowned "
		+ "cell carries a derived row",
		_no_unowned_present(ext, STAT_ADD, world["owned_cells"])
			and _no_unowned_present(ext, STAT_CUT, world["owned_cells"]),
		"add_present=%d cut_present=%d owned=%d" % [pending_present,
			pending_present_cut, owned])

	# ---- A2: the one-shot, emitted ONCE inside the pending batch --------
	print("[PK] ---- A2: the on-enter one-shot while the batch is pending ----")
	var oneshot_pending := _count_oneshot_rows(ext)
	var oneshot_rows := _oneshot_rows(ext)
	print("[PK] A2 one-shot: emitted rows in flight = %d %s"
		% [oneshot_pending, str(oneshot_rows)])
	_expect("A2 one-shot: the level-2 on-enter row is emitted EXACTLY ONCE, at "
		+ "request time, inside the still-pending batch",
		oneshot_pending == 1, "rows=%d %s" % [oneshot_pending,
			str(oneshot_rows)])
	if oneshot_pending == 1:
		var row: Dictionary = oneshot_rows[0]
		_expect("A2 one-shot: the emitted row is a modifier APPLY carrying the "
			+ "authored value %d/Q16 for the real definition %s"
			% [ONESHOT_VALUE_Q16, ONESHOT_DEFINITION_KEY],
			int(row["action"]) == 1 and int(row["domain"]) == 1
				and int(row["opcode"]) == 1
				and int(row["value"]) == ONESHOT_VALUE_Q16
				and String(row["definition"]) == ONESHOT_DEFINITION_KEY,
			str(row))
	_expect("A2 one-shot: no OTHER in-flight row names the same definition "
		+ "(the count is not inflated by the card's own persistent rows)",
		_count_rows_with_definition(ext, ONESHOT_DEFINITION_KEY) == 1,
		"definition_rows=%d" % _count_rows_with_definition(ext,
			ONESHOT_DEFINITION_KEY))

	# ---- A3: settle the level-up; §9.3 defers the L2 basis by one day ----
	#
	# Same three-day shape as A0. The ACK lands on the pass that STARTED the
	# transition; the NEXT pass settles the card and records `confirmed_day = D`,
	# `eligible_from_day = D+1`, and the rebuild is REFUSED on D. Only the day after
	# that does the front carry the L2 pair. "The settled card serves the authored
	# L2 row" is therefore read on D+1, never on D.
	print("[PK] ---- A3: the native adapter handshake ----")
	var level_settle_gen := int(ext.get_derived_cell_layer_report().get(
		"layer_generation", -1))
	var level_gated_before := int(ext.get_ideology_report().get(
		"derived_rebuild_gated_by_eligibility", -1))
	served = _serve(ext, "A/level", true)
	_expect("A3 settle: the native adapters ACKED the level transition's rows",
		bool(served.get("modifier_ok", false))
			and int(served.get("modifier_rejected", -1)) == 0, str(served))
	_tick(ext, "A/level-settle")
	var settle_day_a3 := _ran_day
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("A3 the settle day (L2 basis confirmed, NOT adopted)",
		snap, layer, report)
	var settle_day_add := _covered_add(ext, STAT_ADD)
	var settle_day_cut := _covered_add(ext, STAT_CUT)
	var confirmed_a3 := int(report.get("derived_basis_confirmed_day", -2))
	var eligible_a3 := int(report.get("derived_basis_eligible_day", -3))
	var gated_a3 := int(report.get("derived_rebuild_gated_by_eligibility", -1))
	print("[PK] A3 §9.3: settle day=%d confirmed_day=%d eligible_day=%d gated=%d "
		% [settle_day_a3, confirmed_a3, eligible_a3, gated_a3]
		+ "front add=%.8f cut=%.8f" % [settle_day_add, settle_day_cut])
	_expect("§9.3: the L2 basis is confirmed on the settle day but only eligible "
		+ "the next day", eligible_a3 == confirmed_a3 + 1,
		"confirmed=%s eligible=%s" % [str(confirmed_a3), str(eligible_a3)])
	_expect("§9.3: the L2 confirmation is dated to THIS business day (%d), the "
		% settle_day_a3 + "day the ACK was observed", confirmed_a3 == settle_day_a3,
		"confirmed=%d settle_day=%d" % [confirmed_a3, settle_day_a3])
	_expect("§9.3: the SECOND settle was gate-refused too (the refusal counter "
		+ "moved again, so this is not the first settle's evidence)",
		gated_a3 > level_gated_before,
		"gated %d -> %d" % [level_gated_before, gated_a3])
	_expect("§9.3: on the settle day the front is NOT yet the new basis -- the "
		+ "layer generation the pending measurement saw is kept",
		int(layer.get("layer_generation", -1)) == level_settle_gen,
		"generation %d -> %s" % [level_settle_gen,
			str(layer.get("layer_generation", "?"))])
	_expect("§9.3: on the settle day the front still serves the L1 pair (add "
		+ "%d/Q16, .cut -%d/Q16), NOT the L2 pair" % [L1_ADD_Q16, L1_CUT_Q16],
		absf(settle_day_add - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			and absf(settle_day_cut - (-float(L1_CUT_Q16) / float(Q16_ONE))) <= 1e-6
			and absf(settle_day_add - float(L2_ADD_Q16) / float(Q16_ONE)) > 0.02,
		"settle-day add=%.8f cut=%.8f" % [settle_day_add, settle_day_cut])
	_expect("A3 settle: after the handshake the transition is SETTLED",
		int(report.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	_expect("A3 settle: the card keeps level 1 in the IDEOLOGY slot",
		snap.get("levels", PackedInt32Array()) == PackedInt32Array([1])
			and snap.get("locations", PackedInt32Array())
				== PackedInt32Array([LOCATION_IDEOLOGY]),
		"levels=%s locations=%s" % [str(snap.get("levels", "?")),
			str(snap.get("locations", "?"))])
	_expect("§9.3: on the settle day the front still holds exactly the card's %d "
		% card_rows + "rows -- deferring the basis does not drop the old one",
		int(layer.get("cell_count", -1)) == card_rows
			and _front_contributions(layer) == card_rows,
		"cells=%s contributions=%s expected=%d" % [
			str(layer.get("cell_count", "?")), _front_text(layer), card_rows])

	# ---- A3-basis: the ELIGIBLE day, where the authored L2 pair is published --
	_tick(ext, "A/level-basis-eligible")
	var adopt_day_a3 := _ran_day
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("A3 settled at L2 (basis eligible on day %d)" % _ran_day,
		snap, layer, report)
	var settled_add := _covered_add(ext, STAT_ADD)
	var settled_cut := _covered_add(ext, STAT_CUT)
	print("[PK] A3 magnitudes: add=%.8f cut=%.8f (L2 authored %d/%d Q16)"
		% [settled_add, settled_cut, L2_ADD_Q16, L2_CUT_Q16])
	_expect("A3 settle: the settled content is the AUTHORED L2 row (add %d/Q16, "
		% L2_ADD_Q16 + ".cut -%d/Q16)" % L2_CUT_Q16,
		absf(settled_add - float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			and absf(settled_cut - (-float(L2_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"add=%.8f cut=%.8f" % [settled_add, settled_cut])
	_expect("A3 settle: the front still holds exactly the card's %d rows"
		% card_rows,
		int(layer.get("cell_count", -1)) == card_rows
			and _front_contributions(layer) == card_rows,
		"cells=%s contributions=%s expected=%d" % [
			str(layer.get("cell_count", "?")), _front_text(layer), card_rows])
	_expect("§9.3: the L2 basis is published exactly ONE settle day later -- the "
		+ "settle day served the L1 pair and this adopt day serves the L2 pair",
		absf(settle_day_add - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			and absf(settled_add - float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			and absf(settled_add - settle_day_add) > 0.02,
		"settle day add=%.8f adopt day add=%.8f" % [settle_day_add, settled_add])
	_expect("§9.3: the published front's sample_day is at or after the basis "
		+ "eligibility day (%d) -- a freeze boundary selects only an ELIGIBLE "
		% eligible_a3 + "projection",
		int(layer.get("sample_day", -1)) >= eligible_a3,
		"sample_day=%s eligible=%d" % [str(layer.get("sample_day", "?")),
			eligible_a3])
	if _pending_branch == "NEW":
		_expect("A3 settle [OUTCOME B]: settling changes NOTHING the front did not "
			+ "already show -- the pending value and the settled value are the "
			+ "same number (that is what makes the pending leak invisible to a "
			+ "content check)",
			absf(settled_add - pending_add) <= 1e-9
				and absf(settled_cut - pending_cut) <= 1e-9,
			"pending add=%.10f settled add=%.10f" % [pending_add, settled_add])
		_expect("A3 settle [OUTCOME B]: identical content does not re-install the "
			+ "front from the level change itself (I13: the layer generation the "
			+ "pending measurement saw is kept)",
			int(layer.get("layer_generation", -1))
				== int(gen_before) + _generation_delta(pending_cells, card_rows),
			"generation %d -> %s (front cells %d -> %s)" % [gen_before,
				str(layer.get("layer_generation", "?")), pending_cells,
				str(layer.get("cell_count", "?"))])

	# ---- A4: the one-shot is consumed, and never replayed --------------
	print("[PK] ---- A4: the one-shot across the pending -> settled boundary "
		+ "----")
	var oneshot_settled := _count_oneshot_rows(ext)
	print("[PK] A4 one-shot: rows still in flight after the handshake = %d "
		% oneshot_settled + "(the ACK consumed the batch)")
	_expect("A4 one-shot: the batch is consumed by the ACK -- no on-enter row of "
		+ "this level is still in flight", oneshot_settled == 0,
		"rows=%d" % oneshot_settled)
	var emissions := oneshot_before + oneshot_pending
	_tick(ext, "A/after-settle-1")
	var oneshot_after_1_day := _ran_day
	var oneshot_after_1 := _count_oneshot_rows(ext)
	_tick(ext, "A/after-settle-2")
	var oneshot_after_2_day := _ran_day
	var oneshot_after_2 := _count_oneshot_rows(ext)
	var understanding_end := int((ext.get_ideology_snapshot(handle).get(
		"understanding_q16", PackedInt64Array()) as PackedInt64Array)[0])
	print("[PK] A4 one-shot: emitted %d + %d across the boundary; re-emitted on "
		% [oneshot_before, oneshot_pending]
		+ "day %d = %d, day %d = %d (understanding %d, L3 threshold %d)"
		% [oneshot_after_1_day, oneshot_after_1, oneshot_after_2_day,
			oneshot_after_2, understanding_end, L3_THRESHOLD_Q16])
	_expect("A4 one-shot: running two further ideology days emits NO new "
		+ "on-enter row (entered_levels is latched, so the one-shot is not "
		+ "replayed)", oneshot_after_1 == 0 and oneshot_after_2 == 0,
		"day %d=%d day %d=%d" % [oneshot_after_1_day, oneshot_after_1,
			oneshot_after_2_day, oneshot_after_2])
	_expect("A4 one-shot: the EXACT total number of emissions across the "
		+ "pending -> settled boundary is 1", emissions == 1,
		"emitted=%d (before=%d pending=%d)" % [emissions, oneshot_before,
			oneshot_pending])
	# The strongest count available: the row the one-shot created is a PERMANENT
	# COUNTRY-domain modifier row, so the store itself is a durable ledger. Exactly
	# one such row after the settle and still exactly one after two more days
	# means it fired once and was not replayed.
	var applied_rows := _count_country_key(ext, handle, ONESHOT_DEFINITION_KEY)
	var country_keys_end := _country_modifier_keys(ext, handle)
	print("[PK] A4 one-shot store: %d live COUNTRY-domain row(s) for %s %s"
		% [applied_rows, ONESHOT_DEFINITION_KEY, str(country_keys_end)])
	_expect("A4 one-shot: the Modifier store holds EXACTLY ONE applied row for "
		+ "%s after the settle and after two more days (fired once, never "
		% ONESHOT_DEFINITION_KEY + "replayed)", applied_rows == 1,
		"rows=%d keys=%s" % [applied_rows, str(country_keys_end)])
	_expect("A4: the card is still settled at L2 after the two extra days "
		+ "(the count above is not measuring a card that fell over)",
		int(ext.get_ideology_report().get("pending_transitions", -1)) == 0
			and ext.get_ideology_snapshot(handle).get("levels",
				PackedInt32Array()) == PackedInt32Array([1])
			and absf(_covered_add(ext, STAT_ADD)
				- float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6,
		"pending=%s levels=%s add=%.8f" % [
			str(ext.get_ideology_report().get("pending_transitions", "?")),
			str(ext.get_ideology_snapshot(handle).get("levels", "?")),
			_covered_add(ext, STAT_ADD)])
	_expect("A4: no budget leaked -- the slot budget still shows one occupied "
		+ "IDEOLOGY slot",
		int(ext.get_ideology_snapshot(handle).get("ideology_slots_used", -1)) == 1,
		"slots_used=%s" % str(ext.get_ideology_snapshot(handle).get(
			"ideology_slots_used", "?")))
	_summary.append("A pending: branch=%s add=%.8f cut=%.8f vs L1 %.8f/%.8f "
		% [_pending_branch, pending_add, pending_cut, l1_add_cell, l1_cut_cell]
		+ "and L2 %.8f/%.8f; front %d rows before, %d pending, %d settled"
		% [float(L2_ADD_Q16) / float(Q16_ONE),
			-float(L2_CUT_Q16) / float(Q16_ONE), rows_before, pending_rows,
			_front_contributions(layer)])
	_summary.append("A one-shot: 1 emission across the boundary, 0 replays "
		+ "on the two following days")
	_summary.append("§9.3 gate (A): settle day %d -> confirmed %d / eligible %d, "
		% [settle_day_a, confirmed_a, eligible_a]
		+ "settle day %d -> confirmed %d / eligible %d; the rebuild was refused %d "
		% [settle_day_a3, confirmed_a3, eligible_a3, gated_a3]
		+ "time(s) and the L2 basis was published on day %d" % adopt_day_a3)


## Which authored level the pending measurement landed on. Never guesses: an
## unknown value is "OTHER" and the fixture reports it.
func _classify(add: float, cut: float, l1_add: float, l1_cut: float,
		l2_add: float, l2_cut: float) -> String:
	if absf(add - l1_add) <= 1e-6 and absf(cut - l1_cut) <= 1e-6:
		return "OLD"
	if absf(add - l2_add) <= 1e-6 and absf(cut - l2_cut) <= 1e-6:
		return "NEW"
	return "OTHER"


## The number of times the front had to be re-installed between the L1 baseline
## and the pending measurement. Used only to phrase the generation assertion
## honestly: the level change IS a content change, so one new generation is
## expected the moment the layer first shows the new magnitudes -- nothing is
## claimed beyond that.
func _generation_delta(pending_cells: int, card_rows: int) -> int:
	if pending_cells == card_rows:
		return 1
	return 0


# =========================================================================
# world B: a rejected transition leaves no residue
# =========================================================================

func _phase_b_rejection_no_residue(catalogs: Dictionary, dense: int) -> void:
	print("[PK] ---------- world B: a domain ACK rejects the level transition "
		+ "----------")
	var world: Dictionary = _new_world(catalogs, "B")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var owned: int = int(world["owned"])
	var card_rows: int = 2 * owned

	# ---- B0: settle at L1, then the §9.3 eligibility day -----------------
	#
	# Identical §9.3 shape as A0: the equip settles on D (`confirmed_day = D`,
	# `eligible_from_day = D+1`) and the rebuild is refused on D, so the L1 basis --
	# the "pre-transition value" the whole no-residue measurement is compared
	# against -- is only installed on D+1. Reading it on D is what made the B2/B3
	# baselines 0 instead of the card's 84 rows.
	print("[PK] ---- B0: equip, settle, baseline ----")
	_submit(ext, OP_GRANT, _day, -1, 64 * Q16_ONE, handle, "B/grant")
	_submit(ext, OP_DISCOVER, _day, dense, 0, handle, "B/discover")
	_submit(ext, OP_EQUIP, _day, dense, 0, handle, "B/equip")
	_tick(ext, "B/equip")
	var served := _serve(ext, "B/equip", true)
	_expect("B0 equip settle: the native adapters ACKED the equip's commands",
		bool(served.get("modifier_ok", false))
			and int(served.get("modifier_rejected", -1)) == 0, str(served))
	var b_settle_gen_before := int(ext.get_derived_cell_layer_report().get(
		"layer_generation", -1))
	var b_gated_before := int(ext.get_ideology_report().get(
		"derived_rebuild_gated_by_eligibility", -1))
	_tick(ext, "B/equip-settle")
	var b_settle_day := _ran_day
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var report: Dictionary = ext.get_ideology_report()
	_print_state("B0 the settle day (basis confirmed, NOT adopted)",
		snap, layer, report)
	var b_confirmed := int(report.get("derived_basis_confirmed_day", -2))
	var b_eligible := int(report.get("derived_basis_eligible_day", -3))
	var b_gated_after := int(report.get("derived_rebuild_gated_by_eligibility",
		-1))
	print("[PK] B0 §9.3: settle day=%d confirmed_day=%d eligible_day=%d gated=%d "
		% [b_settle_day, b_confirmed, b_eligible, b_gated_after]
		+ "front installed=%s cells=%s"
		% [str(layer.get("installed", "?")), str(layer.get("cell_count", "?"))])
	_expect("§9.3: the basis is confirmed on the settle day but only eligible the "
		+ "next day", b_eligible == b_confirmed + 1,
		"confirmed=%s eligible=%s" % [str(b_confirmed), str(b_eligible)])
	_expect("§9.3: the confirmation is dated to the business day the ACK was "
		+ "observed (%d)" % b_settle_day, b_confirmed == b_settle_day,
		"confirmed=%d settle_day=%d" % [b_confirmed, b_settle_day])
	_expect("§9.3: adoption was actually refused once (the gate fired, it is not "
		+ "dead)", b_gated_after > b_gated_before,
		"gated %d -> %d" % [b_gated_before, b_gated_after])
	_expect("§9.3: on the settle day the front is NOT yet the new basis -- the "
		+ "layer generation is still the one installed before the settle",
		int(layer.get("layer_generation", -1)) == b_settle_gen_before,
		"generation %d -> %s (installed=%s cells=%s)" % [b_settle_gen_before,
			str(layer.get("layer_generation", "?")),
			str(layer.get("installed", "?")), str(layer.get("cell_count", "?"))])

	# ---- B0-basis: the ELIGIBLE day, where the pre-transition value is real ---
	_tick(ext, "B/basis-eligible")
	snap = ext.get_ideology_snapshot(handle)
	layer = ext.get_derived_cell_layer_report()
	report = ext.get_ideology_report()
	_print_state("B0 settled at L1 (basis eligible on day %d)" % _ran_day,
		snap, layer, report)
	var rows_before := _front_contributions(layer)
	var cells_before := int(layer.get("cell_count", -1))
	var l1_add_cell := _covered_add(ext, STAT_ADD)
	var l1_cut_cell := _covered_add(ext, STAT_CUT)
	var country_rows_before := _country_modifier_rows(ext, handle)
	var country_keys_before := _country_modifier_keys(ext, handle)
	print("[PK] B0 baseline: cells=%d contributions=%d add=%.8f cut=%.8f "
		% [cells_before, rows_before, l1_add_cell, l1_cut_cell]
		+ "country-domain modifier rows=%d %s" % [country_rows_before,
			str(country_keys_before)])
	_expect("B0: the settled card contributes the authored L1 pair and exactly "
		+ "%d front rows" % card_rows,
		cells_before == card_rows and rows_before == card_rows
			and absf(l1_add_cell - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			and absf(l1_cut_cell - (-float(L1_CUT_Q16) / float(Q16_ONE))) <= 1e-6,
		"cells=%d contributions=%d add=%.8f cut=%.8f" % [cells_before,
			rows_before, l1_add_cell, l1_cut_cell])

	# ---- B1: level-up, pending, then a rejecting domain ACK -------------
	print("[PK] ---- B1: level-up, then an ACK that the domain REFUSES ----")
	_submit(ext, OP_ADD_UNDERSTANDING, _day, dense, L2_THRESHOLD_Q16, handle,
		"B/understanding")
	_tick(ext, "B/level")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("B1 level-up (PENDING)", snap, layer, report)
	_expect("B1: the poisoned level-up is IN FLIGHT before the ACK",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	var poison_pending := _count_rows_with_definition(ext, POISON_DEFINITION_KEY)
	var oneshot_pending_b := _count_oneshot_rows(ext)
	print("[PK] B1 in flight: poison rows=%d, on-enter one-shot rows=%d"
		% [poison_pending, oneshot_pending_b])
	_expect("B1: the poisoned on-enter row and the clean one-shot are both in "
		+ "the pending batch (the rejection has not happened yet)",
		poison_pending == 1 and oneshot_pending_b == 1,
		"poison=%d oneshot=%d" % [poison_pending, oneshot_pending_b])

	var rejected_before := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	served = _serve(ext, "B/level", false)
	var rejected_after := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	print("[PK] B1 adapter handshake: modifier ok=%s acknowledged=%s rejected=%s "
		% [str(served.get("modifier_ok", "?")),
			str(served.get("modifier_acknowledged", "?")),
			str(served.get("modifier_rejected", "?"))]
		+ "effect rejected_transactions %d -> %d"
		% [rejected_before, rejected_after])
	_expect("B1: the domain ACK REJECTED exactly one Effect transaction -- the "
		+ "Modifier runtime refuses the unknown definition "
		+ "(modifier_runtime.cpp:997-1000 -> effect_runtime.cpp:5824-5832)",
		int(served.get("modifier_rejected", -1)) == 1
			and rejected_after == rejected_before + 1,
		"rejected=%s rows %d -> %d" % [
			str(served.get("modifier_rejected", "?")), rejected_before,
			rejected_after])
	# The ideology runtime has NOT polled the rejection yet, so the card is still
	# holding the target level. This is the honest intermediate state and it is
	# printed rather than asserted away.
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	print("[PK] B1 pre-poll state: pending_transitions=%s levels=%s "
		% [str(report.get("pending_transitions", "?")),
			str(snap.get("levels", "?"))]
		+ "transition statuses=%s" % str(snap.get(
			"transition_transaction_statuses", "?")))
	var statuses: PackedInt32Array = snap.get("transition_transaction_statuses",
		PackedInt32Array())
	_expect("B1: the transition's own transaction status list already contains "
		+ "the REJECTED code (%d), i.e. the rejection is a durable row and not a "
		% TX_REJECTED + "counter",
		statuses.has(TX_REJECTED), "statuses=%s" % str(statuses))
	_expect("B1: the ideology runtime has not yet polled the rejection, so the "
		+ "card still reports the target level -- the rollback happens on the NEXT "
		+ "ideology day's transition-poll stage (:4918-4924), which is why 'no "
		+ "residue' can only be measured after that day",
		int(report.get("pending_transitions", -1)) == 1,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))

	# ---- B2: the rollback, and the RETRY it is immediately followed by --
	print("[PK] ---- B2: the rollback day ----")
	var levels_advanced_before := int(report.get("levels_advanced", -1))
	_tick(ext, "B/rollback")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("B2 after the rollback day", snap, layer, report)
	var level_receipt := _transition_receipt(ext, dense)
	print("[PK] B2 transition receipt: status=%s opcode=%s reason='%s'"
		% [str(level_receipt.get("status", "?")),
			str(level_receipt.get("opcode", "?")),
			String(level_receipt.get("reason", ""))])
	_expect("B2: the runtime ROLLED THE CARD BACK and wrote a REJECTED "
		+ "transition receipt with reason '%s'" % REASON_TRANSITION_REJECTED,
		int(level_receipt.get("status", -1)) == RECEIPT_REJECTED
			and String(level_receipt.get("reason", ""))
				== REASON_TRANSITION_REJECTED,
		"status=%s reason='%s'" % [str(level_receipt.get("status", "?")),
			String(level_receipt.get("reason", ""))])
	var levels_advanced_after := int(report.get("levels_advanced", -1))
	var retry_visible: bool = int(report.get("pending_transitions", -1)) == 1 \
		and snap.get("levels", PackedInt32Array()) == PackedInt32Array([1]) \
		and levels_advanced_after >= levels_advanced_before + 2
	print("[PK] B2 rollback aftermath: levels_advanced %d -> %d, "
		% [levels_advanced_before, levels_advanced_after]
		+ "pending_transitions=%s levels=%s"
		% [str(report.get("pending_transitions", "?")),
			str(snap.get("levels", "?"))])
	if retry_visible:
		print("[PK] [FINDING] a rejected level-up is RETRIED inside the SAME "
			+ "`run_ideology_daily` slice. Slice order is poll (rollback) -> "
			+ "commands -> active progress (ideology_runtime.cpp:4918-5035), and "
			+ "the rollback restores previous_level while understanding still "
			+ "clears the L2 threshold, so `start_next_level_transition` "
			+ "(:5022) re-opens the transition immediately: state.level is "
			+ "written back to the target at REQUEST time (:3598) and the front "
			+ "is rebuilt for it. Consequence: between two rollbacks the card's "
			+ "per-cell contribution NEVER shows the reverted L1 values -- the "
			+ "revert is real in `state` (the receipt proves it) but "
			+ "unobservable in the layer. A permanently failing transition "
			+ "therefore re-emits its batch every other day AND keeps serving "
			+ "the target level's magnitudes. 'A rejection leaves no residue' "
			+ "is measured below as NO ACCUMULATION instead of as a visible "
			+ "revert, and world C measures the visible revert on the one "
			+ "transition command kind that is not retried (equip).")
	_expect("B2: the retry is honestly what the runtime does -- the rollback and "
		+ "the re-opened transition happen in the same day (otherwise the card "
		+ "would sit at level 0 and this check would say so)",
		not retry_visible
			or (levels_advanced_after >= levels_advanced_before + 2
				and int(report.get("pending_transitions", -1)) == 1),
		"levels_advanced %d -> %d pending=%s" % [levels_advanced_before,
			levels_advanced_after,
			str(report.get("pending_transitions", "?"))])

	# ---- B2-numeric: no residue means NO ACCUMULATION --------------------
	var rej_add := _covered_add(ext, STAT_ADD)
	var rej_cut := _covered_add(ext, STAT_CUT)
	var rej_rows := _front_contributions(layer)
	var rej_cells := int(layer.get("cell_count", -1))
	print("[PK] B2-NUMERIC per-cell: add=%.8f cut=%.8f, front cells=%d "
		% [rej_add, rej_cut, rej_cells]
		+ "contributions=%d (pre-transition: cells=%d contributions=%d)"
		% [rej_rows, cells_before, rows_before])
	_expect("B2 no residue: the front's contribution_count is UNCHANGED at the "
		+ "PRE-TRANSITION value %d -- the rejection added no orphan row" % rows_before,
		rej_rows == rows_before and rej_cells == cells_before,
		"cells %d -> %d, contributions %d -> %d" % [cells_before, rej_cells,
			rows_before, rej_rows])
	_expect("B2 no residue: the row count did not DOUBLE (%d, not %d)"
		% [card_rows, 2 * card_rows],
		rej_rows == card_rows, "contributions=%d expected=%d" % [rej_rows,
			card_rows])
	_expect("B2 no residue: no unowned cell carries a derived row (no orphan)",
		_no_unowned_present(ext, STAT_ADD, world["owned_cells"])
			and _no_unowned_present(ext, STAT_CUT, world["owned_cells"]),
		"add_present=%d cut_present=%d owned=%d" % [_present_count(ext,
			STAT_ADD), _present_count(ext, STAT_CUT), owned])
	_expect("B2 no residue: the emitted content is still exactly one authored "
		+ "level -- add=%.8f is the L2 value and not a sum of two levels"
		% (float(L2_ADD_Q16) / float(Q16_ONE)),
		absf(rej_add - float(L2_ADD_Q16) / float(Q16_ONE)) <= 1e-6
			or absf(rej_add - float(L1_ADD_Q16) / float(Q16_ONE)) <= 1e-6,
		"add=%.8f L1=%.8f L2=%.8f" % [rej_add,
			float(L1_ADD_Q16) / float(Q16_ONE),
			float(L2_ADD_Q16) / float(Q16_ONE)])
	var country_rows_after := _country_modifier_rows(ext, handle)
	var country_keys_after := _country_modifier_keys(ext, handle)
	var residue := _key_residue(country_keys_before, country_keys_after)
	print("[PK] B2 country-domain modifier rows: %d -> %d %s"
		% [country_rows_before, country_rows_after, str(country_keys_after)])
	print("[PK] B2 country-domain residue (rows the rejected batch left): %s"
		% (str(residue) if not residue.is_empty() else "none"))
	if residue.is_empty():
		print("[PK] [OK] rejection left no COUNTRY-domain modifier row behind")
	else:
		print("[PK] [FINDING] the rejected transition left %d COUNTRY-domain "
			% residue.size()
			+ "modifier row(s) behind: %s. Cause: the Modifier domain applies "
			% str(residue)
			+ "each row of the batch in submission order inside "
			+ "`run_modifier_daily`, and only THEN does `ack_effect_native_modifier` "
			+ "see the failing row and mark the transaction REJECTED "
			+ "(effect_runtime.cpp:5801-5832). `apply_rejected_instance_transition` "
			+ "does not reverse commands that already committed, so the rows that "
			+ "preceded the failing one stay in the store. Consequence for the plan "
			+ "line (...plan-v3.md:1526): 'a rejection leaves no residue' holds for "
			+ "the DERIVED cell layer and for the ideology state (measured above: "
			+ "contribution_count unchanged, no orphan, no doubling) but NOT for the "
			+ "Modifier domain. Note also that the on-enter one-shot "
			+ "(ideology.standardization) is among the survivors: the rejected batch "
			+ "still EXECUTED the one-shot rows that preceded the failing row.")
	_expect("B2 [measured]: any COUNTRY-domain row the rejected batch leaves "
		+ "behind is confined to that batch (the card's cost definition and the "
		+ "fixture's on-enter row) -- no unrelated definition appeared",
		_residue_confined(residue), str(residue))

	# ---- B3: a second reject/retry cycle must not accumulate ------------
	print("[PK] ---- B3: a second reject/retry cycle ----")
	var rejected_cycle_1 := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	_tick(ext, "B/cycle2-pending")
	var poison_cycle_2 := _count_rows_with_definition(ext, POISON_DEFINITION_KEY)
	print("[PK] B3 cycle 2 pending: poison rows in flight=%d" % poison_cycle_2)
	_expect("B3: the retried transition re-emits the on-enter batch EXACTLY "
		+ "once per cycle (no doubling inside one cycle)",
		poison_cycle_2 == 1, "poison=%d" % poison_cycle_2)
	served = _serve(ext, "B/cycle2", false)
	_tick(ext, "B/cycle2-rollback")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	var rejected_cycle_2 := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	var cycle2_add := _covered_add(ext, STAT_ADD)
	var cycle2_rows := _front_contributions(layer)
	var cycle2_cells := int(layer.get("cell_count", -1))
	_print_state("B3 after the second rejection", snap, layer, report)
	print("[PK] B3 cycle 2: rejected_transactions %d -> %d, add=%.8f, front "
		% [rejected_cycle_1, rejected_cycle_2, cycle2_add]
		+ "cells=%d contributions=%d" % [cycle2_cells, cycle2_rows])
	_expect("B3 no residue: the second rejection rejected exactly one more "
		+ "transaction (the cycle really repeated)",
		int(served.get("modifier_rejected", -1)) == 1
			and rejected_cycle_2 == rejected_cycle_1 + 1,
		"rejected=%s rows %d -> %d" % [
			str(served.get("modifier_rejected", "?")), rejected_cycle_1,
			rejected_cycle_2])
	_expect("B3 no residue: after TWO rejection cycles the front still holds "
		+ "exactly %d contributions -- nothing accumulated, nothing doubled"
		% rows_before,
		cycle2_rows == rows_before and cycle2_cells == cells_before,
		"cells=%d contributions=%d expected=%d/%d" % [cycle2_cells, cycle2_rows,
			cells_before, rows_before])
	_expect("B3 no residue: after TWO rejection cycles no unowned cell carries "
		+ "a derived row",
		_no_unowned_present(ext, STAT_ADD, world["owned_cells"])
			and _no_unowned_present(ext, STAT_CUT, world["owned_cells"]),
		"add_present=%d cut_present=%d" % [_present_count(ext, STAT_ADD),
			_present_count(ext, STAT_CUT)])
	_expect("B3 no residue: the economy stayed conserved through both "
		+ "rejection cycles (population / money / goods errors are 0)",
		_audit_clean(ext), str(ext.get_economy_committed_audit_report()))
	# §9.3 negative evidence in the world that DOES have a confirmed basis: the two
	# basis days are written only on the success branch of
	# `poll_pending_transition` (`ideology_runtime.cpp:3837-3846`), so two REJECTED
	# transitions must leave them exactly where the equip settle put them.
	_expect("§9.3: two REJECTED transitions did not move the basis dates -- a "
		+ "rejection produces no projection",
		int(report.get("derived_basis_confirmed_day", -2)) == b_confirmed
			and int(report.get("derived_basis_eligible_day", -3)) == b_eligible,
		"confirmed=%s eligible=%s (unchanged from the settle: %d/%d)" % [
			str(report.get("derived_basis_confirmed_day")),
			str(report.get("derived_basis_eligible_day")), b_confirmed, b_eligible])
	_summary.append("B rejection (level-up): the domain ACK rejected the batch "
		+ "(modifier_definition_unknown) and the runtime rolled the card back, "
		+ "but the SAME slice retried it -- front stayed at %d rows and %.8f "
		% [rows_before, rej_add]
		+ "through TWO cycles, with no orphan and no doubling")
	# §9.3 in this world: only the equip ever settled, so the two basis days stay
	# at that settle's values through BOTH rejections -- a rejected transition
	# produces no projection and therefore cannot move the dates.
	_summary.append("§9.3 gate (B): the equip settled on day %d -> confirmed %d / "
		% [b_settle_day, b_confirmed]
		+ "eligible %d, refused %d time(s); both rejections left the dates "
		% [b_eligible, b_gated_after]
		+ "unchanged at %s/%s" % [
			str(report.get("derived_basis_confirmed_day")),
			str(report.get("derived_basis_eligible_day"))])


# =========================================================================
# world C: a rejected EQUIP, which nothing retries
# =========================================================================

## World B shows the rollback receipt but the immediate retry masks the reverted
## layer. `equip` is the one transition command kind that is NOT re-issued by any
## periodic stage, so a rejected equip is the clean place to observe "the
## contribution reverts to the pre-transition value and stays there".
##
## Pre-transition value here is ZERO rows: the card was never equipped. So the
## assertion is the strongest possible form of "no residue" -- after the rejection
## the front holds no row at all, no cell carries a derived contribution, and the
## slot budget is released.
func _phase_c_rejected_equip_no_residue(catalogs: Dictionary, dense: int) -> void:
	print("[PK] ---------- world C: a domain ACK rejects the EQUIP (nothing "
		+ "retries it) ----------")
	var world: Dictionary = _new_world(catalogs, "C")
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var owned: int = int(world["owned"])
	var card_rows: int = 2 * owned

	# ---- C0: baseline -- no card, no contribution -----------------------
	print("[PK] ---- C0: baseline (no card equipped) ----")
	var baseline_layer: Dictionary = ext.get_derived_cell_layer_report()
	var baseline_rows := _front_contributions(baseline_layer)
	var country_keys_before := _country_modifier_keys(ext, handle)
	print("[PK] C0 baseline: installed=%s cells=%s contributions=%s add_present=%d "
		% [str(baseline_layer.get("installed", "?")),
			str(baseline_layer.get("cell_count", "?")), _front_text(baseline_layer),
			_present_count(ext, STAT_ADD)]
		+ "country-domain modifier rows=%d %s" % [country_keys_before.size(),
			str(country_keys_before)])
	_expect("C0: with no card equipped the front holds no row at all",
		baseline_rows == 0 and _present_count(ext, STAT_ADD) == 0
			and _present_count(ext, STAT_CUT) == 0,
		"contributions=%d add_present=%d" % [baseline_rows,
			_present_count(ext, STAT_ADD)])

	# ---- C1: equip -> pending, with the poisoned on-enter row ----------
	#
	# Plan §9.3 needs no extra day in this world: the equip is REJECTED, a rejected
	# transition produces no projection, so `confirmed_day` / `eligible_from_day`
	# stay at -1 and the eligibility gate never fires (asserted in C3). The day
	# numbering therefore matches the pre-§9.3 shape.
	print("[PK] ---- C1: equip, with the poisoned on-enter row in the batch ----")
	_submit(ext, OP_GRANT, _day, -1, 64 * Q16_ONE, handle, "C/grant")
	_submit(ext, OP_DISCOVER, _day, dense, 0, handle, "C/discover")
	_submit(ext, OP_EQUIP, _day, dense, 0, handle, "C/equip")
	_tick(ext, "C/equip")
	var snap: Dictionary = ext.get_ideology_snapshot(handle)
	var report: Dictionary = ext.get_ideology_report()
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	_print_state("C1 equip (PENDING)", snap, layer, report)
	var poison_rows := _count_rows_with_definition(ext, POISON_DEFINITION_KEY)
	print("[PK] C1 in flight: poison rows=%d, front cells=%s contributions=%s"
		% [poison_rows, str(layer.get("cell_count", "?")), _front_text(layer)])
	_expect("C1: the equip is in flight and its batch carries the poisoned "
		+ "on-enter row exactly once",
		int(report.get("pending_transitions", -1)) == 1 and poison_rows == 1,
		"pending=%s poison=%d" % [
			str(report.get("pending_transitions", "?")), poison_rows])
	# FLIPPED 2026-10-28 (user decision): plan §10.1 is now implemented, so a PENDING EQUIP
	# contributes NOTHING -- `collect_effect_activations` returns early while a transition is
	# active and the card had no previous location.
	#
	# This assertion used to pin the opposite (a pending equip publishing `card_rows` rows,
	# because `start_transition` wrote `location` at request time). It is the exact inverse
	# now, so a regression flips it straight back to red.
	_expect("C1 [10.1]: while the equip is pending the front does NOT list the card "
		+ "(a pending EQUIP contributes nothing)",
		int(layer.get("cell_count", 0)) == 0
			and _front_contributions(layer) == 0,
		"cells=%s contributions=%s (a pending equip used to publish %d rows)" % [
			str(layer.get("cell_count", "?")), _front_text(layer), card_rows])

	# ---- C2: the domain ACK rejects the equip --------------------------
	print("[PK] ---- C2: the domain ACK rejects it ----")
	var rejected_before := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	var served_c := _serve(ext, "C/equip", false)
	var rejected_after := int(ext.get_effect_report().get(
		"rejected_transactions", -1))
	print("[PK] C2 adapter handshake: modifier ok=%s acknowledged=%s rejected=%s "
		% [str(served_c.get("modifier_ok", "?")),
			str(served_c.get("modifier_acknowledged", "?")),
			str(served_c.get("modifier_rejected", "?"))]
		+ "effect rejected_transactions %d -> %d"
		% [rejected_before, rejected_after])
	_expect("C2: the domain ACK rejected exactly one transaction",
		int(served_c.get("modifier_rejected", -1)) == 1
			and rejected_after == rejected_before + 1,
		"rejected=%s rows %d -> %d" % [
			str(served_c.get("modifier_rejected", "?")), rejected_before,
			rejected_after])

	# ---- C3: the rollback, and the reverted contribution ---------------
	print("[PK] ---- C3: the rollback day ----")
	_tick(ext, "C/rollback")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("C3 after the rejected equip", snap, layer, report)
	var equip_receipt := _transition_receipt(ext, dense)
	print("[PK] C3 transition receipt: status=%s opcode=%s reason='%s'"
		% [str(equip_receipt.get("status", "?")),
			str(equip_receipt.get("opcode", "?")),
			String(equip_receipt.get("reason", ""))])
	_expect("C3: the runtime ROLLED THE EQUIP BACK and wrote a REJECTED "
		+ "transition receipt with reason '%s'" % REASON_TRANSITION_REJECTED,
		int(equip_receipt.get("status", -1)) == RECEIPT_REJECTED
			and String(equip_receipt.get("reason", ""))
				== REASON_TRANSITION_REJECTED,
		"status=%s reason='%s'" % [str(equip_receipt.get("status", "?")),
			String(equip_receipt.get("reason", ""))])
	var revert_rows := _front_contributions(layer)
	var revert_cells := int(layer.get("cell_count", -1))
	var revert_add_present := _present_count(ext, STAT_ADD)
	var revert_cut_present := _present_count(ext, STAT_CUT)
	# §9.3: a REJECTED transition never confirms a projection. `poll_pending_transition`
	# records the two days only on the success branch
	# (`ideology_runtime.cpp:3837-3846`), so a world that only ever rejects must keep
	# both at -1 and must never trip the eligibility gate -- which is why this world
	# needs no extra day. This is the negative half of the §9.3 evidence.
	print("[PK] C3 §9.3: confirmed_day=%s eligible_day=%s gated=%s "
		% [str(report.get("derived_basis_confirmed_day")),
			str(report.get("derived_basis_eligible_day")),
			str(report.get("derived_rebuild_gated_by_eligibility"))]
		+ "(a rejected transition produces NO projection)")
	_expect("§9.3: the REJECTED equip confirmed no projection -- both basis days "
		+ "stay unset (-1) and the eligibility gate never fired",
		int(report.get("derived_basis_confirmed_day", 0)) == -1
			and int(report.get("derived_basis_eligible_day", 0)) == -1
			and int(report.get("derived_rebuild_gated_by_eligibility", -1)) == 0,
		"confirmed=%s eligible=%s gated=%s" % [
			str(report.get("derived_basis_confirmed_day")),
			str(report.get("derived_basis_eligible_day")),
			str(report.get("derived_rebuild_gated_by_eligibility"))])
	print("[PK] C3 REVERTED front: installed=%s cells=%d contributions=%d "
		% [str(layer.get("installed", "?")), revert_cells, revert_rows]
		+ "(pre-transition: cells=0 contributions=0), add_present=%d cut_present=%d"
		% [revert_add_present, revert_cut_present])
	_expect("C3 no residue: the front's contribution_count is back to the "
		+ "PRE-TRANSITION value 0 (no orphan row left by the rejected equip)",
		revert_rows == 0 and revert_cells == 0,
		"cells=%d contributions=%d installed=%s" % [revert_cells, revert_rows,
			str(layer.get("installed", "?"))])
	_expect("C3 no residue: NO cell carries a derived contribution -- the "
		+ "rejected equip left nothing on any of the %d cells, owned or not"
		% CELLS,
		revert_add_present == 0 and revert_cut_present == 0,
		"add_present=%d cut_present=%d" % [revert_add_present, revert_cut_present])
	_expect("C3 no residue: the card is back to INACTIVE and the slot budget is "
		+ "released",
		snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_INACTIVE])
			and int(snap.get("ideology_slots_used", -1)) == 0
			and int(report.get("pending_transitions", -1)) == 0,
		"locations=%s slots_used=%s pending=%s" % [
			str(snap.get("locations", "?")),
			str(snap.get("ideology_slots_used", "?")),
			str(report.get("pending_transitions", "?"))])
	var country_rows_c := _country_modifier_rows(ext, handle)
	var country_keys_c := _country_modifier_keys(ext, handle)
	var residue_c := _key_residue(country_keys_before, country_keys_c)
	print("[PK] C3 country-domain modifier rows after the rejection: %d -> %d %s"
		% [country_keys_before.size(), country_rows_c, str(country_keys_c)])
	print("[PK] C3 country-domain residue (rows the rejected equip left): %s"
		% (str(residue_c) if not residue_c.is_empty() else "none"))
	if residue_c.is_empty():
		print("[PK] [OK] the rejected equip left no COUNTRY-domain modifier row "
			+ "behind")
	else:
		print("[PK] [FINDING] the rejected EQUIP left %d COUNTRY-domain modifier "
			% residue_c.size()
			+ "row(s) behind: %s. The equip was rolled back to INACTIVE "
			% str(residue_c)
			+ "(locations=[0], slots_used=0) and contributes NOTHING to the "
			+ "derived layer, yet the country keeps a cost modifier row the "
			+ "rejected batch applied before its failing row was reached -- the "
			+ "same Modifier-domain residue as world B, now with the card fully "
			+ "unequipped, which makes it unambiguous that the row is orphaned.")
	_expect("C3 [measured]: any COUNTRY-domain row the rejected equip leaves "
		+ "behind is confined to that batch (only the card's own cost definition)",
		_residue_confined(residue_c), str(residue_c))

	# ---- C4: nothing comes back ----------------------------------------
	print("[PK] ---- C4: two further ideology days ----")
	_tick(ext, "C/day2")
	_tick(ext, "C/day3")
	snap = ext.get_ideology_snapshot(handle)
	report = ext.get_ideology_report()
	layer = ext.get_derived_cell_layer_report()
	_print_state("C4 two days after the rejected equip", snap, layer, report)
	var late_rows := _front_contributions(layer)
	print("[PK] C4: cells=%s contributions=%s add_present=%d cut_present=%d "
		% [str(layer.get("cell_count", "?")), _front_text(layer),
			_present_count(ext, STAT_ADD), _present_count(ext, STAT_CUT)]
		+ "slots_used=%s" % str(snap.get("ideology_slots_used", "?")))
	_expect("C4 no residue: two days later the front still holds nothing and no "
		+ "cell carries a contribution",
		late_rows == 0 and _present_count(ext, STAT_ADD) == 0
			and _present_count(ext, STAT_CUT) == 0,
		"contributions=%d add_present=%d" % [late_rows,
			_present_count(ext, STAT_ADD)])
	_expect("C4 no residue: the card stays INACTIVE and no transition was "
		+ "re-opened (nothing retries an equip)",
		snap.get("locations", PackedInt32Array())
			== PackedInt32Array([LOCATION_INACTIVE])
			and int(report.get("pending_transitions", -1)) == 0,
		"locations=%s pending=%s" % [str(snap.get("locations", "?")),
			str(report.get("pending_transitions", "?"))])
	_expect("C4 no residue: the economy stayed conserved through the rejected "
		+ "equip", _audit_clean(ext),
		str(ext.get_economy_committed_audit_report()))
	_summary.append("C rejection (equip): domain ACK rejected 1 transaction, the "
		+ "card rolled back to INACTIVE, front contributions 0 (from a pending "
		+ "%d), no cell covered, slot released, and nothing came back" % card_rows)
	_summary.append("§9.3 gate (C): never fired -- the equip was rejected, so "
		+ "confirmed/eligible stayed -1/-1 and the gate was never consulted")


# =========================================================================
# the one-shot / in-flight row probes
# =========================================================================

## Every command row of every unclaimed in-flight Effect transaction, flattened.
## `poll_effect_transactions` skips transactions a native adapter has already
## claimed (`effect_runtime.cpp:6583-6595`), which is exactly what lets this
## fixture see the emitted batch BEFORE the handshake and nothing after it.
func _in_flight_rows(ext: Object) -> Array:
	var raw: Dictionary = ext.poll_effect_transactions(0, 256)
	var offsets: PackedInt32Array = raw.get("command_offsets", PackedInt32Array())
	var definitions: PackedStringArray = raw.get("command_definition_keys",
		PackedStringArray())
	var keys: PackedStringArray = raw.get("command_keys", PackedStringArray())
	var actions: PackedInt32Array = raw.get("command_actions", PackedInt32Array())
	var domains: PackedInt32Array = raw.get("command_domains", PackedInt32Array())
	var opcodes: PackedInt32Array = raw.get("command_opcodes", PackedInt32Array())
	var values: PackedInt64Array = raw.get("command_values_q16", PackedInt64Array())
	var out: Array = []
	var transaction_count := int(raw.get("count", 0))
	if transaction_count <= 0:
		transaction_count = maxi(0, offsets.size() - 1)
	for t in range(transaction_count):
		if t + 1 >= offsets.size():
			break
		for c in range(int(offsets[t]), int(offsets[t + 1])):
			out.append({
				"transaction_index": t,
				"key": String(keys[c]) if c < keys.size() else "",
				"definition": String(definitions[c]) if c < definitions.size() else "",
				"action": int(actions[c]) if c < actions.size() else -1,
				"domain": int(domains[c]) if c < domains.size() else -1,
				"opcode": int(opcodes[c]) if c < opcodes.size() else -1,
				"value": int(values[c]) if c < values.size() else 0,
			})
	return out


## The on-enter one-shot rows world A injected, identified by their command key so
## the card's own persistent/cost rows cannot inflate the count.
func _oneshot_rows(ext: Object) -> Array:
	var out: Array = []
	for row in _in_flight_rows(ext):
		if String(row["key"]) == ONESHOT_COMMAND_KEY:
			out.append(row)
	return out


func _count_oneshot_rows(ext: Object) -> int:
	return _oneshot_rows(ext).size()


func _count_rows_with_definition(ext: Object, definition_key: String) -> int:
	var count := 0
	for row in _in_flight_rows(ext):
		if String(row["definition"]) == definition_key:
			count += 1
	return count


## How many LIVE COUNTRY-domain modifier rows the store holds for one definition.
## This is the durable one-shot ledger: a permanent applied row cannot be
## "consumed", so a count of exactly 1 after N further days is the strongest
## statement that the one-shot fired once and was never replayed.
func _count_country_key(ext: Object, handle: int, definition_key: String) -> int:
	var count := 0
	for key in _country_modifier_keys(ext, handle):
		if String(key) == definition_key:
			count += 1
	return count


## Country-domain modifier rows for the fixture country. Used only for the
## "no doubled rows" half of "no residue": a rejected transition must never leave
## more rows behind than it started with.
func _country_modifier_rows(ext: Object, handle: int) -> int:
	var rows: Dictionary = ext.list_modifiers(1, handle, "")
	if not bool(rows.get("ok", false)):
		return -1
	return (rows.get("definition_keys", PackedStringArray()) as PackedStringArray).size()


## The definition keys of the live COUNTRY-domain modifier rows, so a log line can
## name what a rejected equip left behind instead of only counting it.
func _country_modifier_keys(ext: Object, handle: int) -> PackedStringArray:
	var rows: Dictionary = ext.list_modifiers(1, handle, "")
	if not bool(rows.get("ok", false)):
		return PackedStringArray()
	return rows.get("definition_keys", PackedStringArray())


## Multiset difference `after - before` over definition keys: the rows that exist
## after a rejected transition and did not exist before it. Sorted, so a log line
## and a failure message are stable across runs.
func _key_residue(before: PackedStringArray, after: PackedStringArray) -> PackedStringArray:
	var remaining := {}
	for key in before:
		remaining[key] = int(remaining.get(key, 0)) + 1
	var added := PackedStringArray()
	for key in after:
		var count := int(remaining.get(key, 0))
		if count > 0:
			remaining[key] = count - 1
		else:
			added.append(key)
	added.sort()
	return added


## True when every surviving row comes from the SAME batch the rejection killed:
## the card's own cost definition and the fixture's on-enter row. A foreign
## definition appearing there would mean the rejection leaked into unrelated
## state, which is a strictly worse defect than the one measured here.
func _residue_confined(residue: PackedStringArray) -> bool:
	for key in residue:
		if key != COST_DEFINITION_KEY and key != ONESHOT_DEFINITION_KEY:
			return false
	return true


func _audit_clean(ext: Object) -> bool:
	var audit: Dictionary = ext.get_economy_committed_audit_report()
	return bool(audit.get("available", false)) \
		and int(audit.get("population_error", -1)) == 0 \
		and int(audit.get("money_error", -1)) == 0 \
		and int(audit.get("goods_error", -1)) == 0


# =========================================================================
# production side channel: the native Effect adapters
# =========================================================================

## The production handshake (`world_ext_bind_methods.cpp:635-648`):
##
##   dispatch_effect_native_modifier()  ->  run_modifier_daily(day)
##                                      ->  ack_effect_native_modifier()
##
## plus the country pair, which this fixture keeps running so a batch that also
## carries a country row cannot be starved. `expect_clean` distinguishes the two
## modes honestly: world A requires every ACK to succeed, world B requires the
## modifier ACK to reject exactly one transaction.
func _serve_native_adapters(ext: Object, day: int, label: String,
		expect_clean: bool) -> Dictionary:
	var rounds := 0
	var acknowledged := 0
	var rejected := 0
	var modifier_ok := true
	var last_modifier: Dictionary = {}
	for _i in range(8):
		rounds += 1
		ext.run_effect_daily(day)
		var d_mod: Dictionary = ext.dispatch_effect_native_modifier()
		ext.run_modifier_daily(day)
		var a_mod: Dictionary = ext.ack_effect_native_modifier()
		var d_cty: Dictionary = ext.dispatch_effect_native_country()
		var a_cty: Dictionary = ext.ack_effect_native_country()
		last_modifier = a_mod
		acknowledged += int(a_mod.get("acknowledged", 0))
		rejected += int(a_mod.get("rejected", 0))
		if rounds == 1:
			print("[PK/%s/adapters] r1 modifier dispatch=%s ack=%s country=%s/%s"
				% [label, str(d_mod), str(a_mod), str(d_cty), str(a_cty)])
		if not bool(d_mod.get("ok", true)):
			modifier_ok = false
			break
		if expect_clean and not bool(a_mod.get("ok", true)):
			modifier_ok = false
			print("[PK/%s/adapters] unexpected modifier rejection: %s"
				% [label, str(a_mod)])
			break
		if not bool(d_cty.get("ok", true)) or not bool(a_cty.get("ok", true)):
			print("[PK/%s/adapters] country adapter: %s / %s"
				% [label, str(d_cty), str(a_cty)])
		if int(a_mod.get("pending", 0)) == 0 \
				and (acknowledged > 0 or rejected > 0):
			break
	var pre_poll := int(ext.get_ideology_report().get(
		"pending_transitions", -1))
	print("[PK/%s/adapters] rounds=%d modifier aked=%d rejected=%d "
		% [label, rounds, acknowledged, rejected]
		+ "pre_poll_pending_transitions=%d" % pre_poll)
	return {"rounds": rounds, "modifier_ok": modifier_ok,
		"modifier_acknowledged": acknowledged, "modifier_rejected": rejected,
		"pre_poll_pending_transitions": pre_poll,
		"last_modifier": last_modifier}


# =========================================================================
# catalogs (the resource-configuration technique)
# =========================================================================

## Compiles the four native catalogs for one world.
##
## Order is load-bearing. `EffectDomainCatalog.build()` compiles the IDEOLOGY
## catalog internally to register one Effect command definition per ideology
## on-enter/persistent/synergy row
## (`scripts/effect/effect_domain_catalog.gd:431-447`, `:875-920`). So the Level
## RESOURCE must be configured BEFORE the domain is compiled, or the row would be
## emitted with no matching definition and `enqueue_external_effect_batch_pod`
## would refuse the whole batch with
## `effect_external_batch_definition_not_compiled`
## (`effect_runtime.cpp:3518-3521`).
##
## `poison_level` is 1 for the level-up rejection world, 0 for the rejected-equip
## world, and -1 for the numeric world.
func _compile_catalogs(label: String, poison_level: int) -> Dictionary:
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	country_ir.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile["market_cycle_days"] = 1
	profile["market_runtime_mode"] = "ACTIVE"

	var catalog: Resource = IdeologyCatalogScript.load_default()
	if not _install_on_enter_rows(catalog, poison_level):
		_expect("catalog %s: the card %s resolves with the levels to configure"
			% [label, CARD_KEY], false, "")
		return {}

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

	var ids: PackedStringArray = native_ideology.get("ideology_ids",
		PackedStringArray())
	var dense: int = ids.find(CARD_KEY)
	_expect("catalog %s: the card %s is in the compiled ideology catalog"
		% [label, CARD_KEY], dense >= 0, "dense=%d of %d" % [dense, ids.size()])
	if dense < 0:
		return {}
	# The injected on-enter row must have produced a compiled Effect command
	# definition, otherwise the transition batch cannot be enqueued at all.
	var def_keys: PackedStringArray = effect_ir.get("command_definition_keys",
		PackedStringArray())
	var key_index: int = def_keys.find(ONESHOT_DEFINITION_KEY)
	_expect("catalog %s: the injected on-enter one-shot compiled an Effect "
		% label + "command definition for %s (that is what makes the row "
			% ONESHOT_DEFINITION_KEY + "emittable)", key_index >= 0,
		"%s at %d of %d command definitions" % [ONESHOT_DEFINITION_KEY, key_index,
			def_keys.size()])
	var poison_index: int = def_keys.find(POISON_DEFINITION_KEY)
	if poison_level >= 0:
		_expect("catalog %s: the poisoned on-enter row on level %d ALSO compiled a "
			% [label, poison_level] + "command definition for %s (the rejection "
			% POISON_DEFINITION_KEY + "must come from the Modifier catalog, not "
			+ "from a missing Effect definition)", poison_index >= 0,
			"%s at %d" % [POISON_DEFINITION_KEY, poison_index])
		var modifier_keys: PackedStringArray = mod_ir.get("definition_keys",
			PackedStringArray())
		_expect("catalog %s: the poisoned definition really is ABSENT from the "
			% label + "Modifier catalog, which is what makes the domain ACK "
			+ "refuse it", modifier_keys.find(POISON_DEFINITION_KEY) < 0,
			"present=%s" % str(modifier_keys.find(POISON_DEFINITION_KEY) >= 0))
	else:
		_expect("catalog %s: the poisoned row is NOT injected in this world"
			% label, poison_index < 0,
			"present at %d" % poison_index)

	_summary.append("catalog %s: %d ideology ids, %d effect programs, "
		% [label, ids.size(), (effect_ir.get("effect_keys",
			PackedStringArray()) as PackedStringArray).size()]
		+ "%d modifier definitions" % (mod_ir.get("definition_keys",
			PackedStringArray()) as PackedStringArray).size())
	print("[PK/catalog] %s: dense=%d, %d effect programs, one-shot command "
		% [label, dense, def_keys.size()]
		+ "definition at %d, poison at %d" % [key_index, poison_index])
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	economy_catalog.erase("ok")
	return {
		"label": label, "country_ir": country_ir, "profile": profile,
		"effect_ir": effect_ir, "mod_ir": mod_ir,
		"native_ideology": native_ideology, "economy_catalog": economy_catalog,
		"dense": dense,
	}


## Appends the fixture's on-enter rows to `idea.public_hygiene` on the catalog
## RESOURCE.
##
## Level 2 always receives the clean one-shot; the shipped level 2 has an empty
## on-enter list (`default_ideology_catalog.tres:5334`) and the shipped level 1 has
## one too (`:5302`), so both injections are purely additive.
##
## `poison_level` selects the level whose batch the rejection probe rides in:
##   1 -> the LEVEL-UP batch carries it (world B)
##   0 -> the EQUIP batch carries it (world C, because `equip` enters level 0 via
##        `unentered_level_mask(*state, state->level)`,
##        `ideology_runtime.cpp:4566-4569`)
##   -1 -> no poison row at all
##
## Both rows are plain modifier APPLYs on a COUNTRY-domain definition
## (`target_resolver` 1 = TARGET_INSTANCE, the only resolver the ideology compiler
## accepts), which is what `_append_effect_rows` checks
## (`scripts/ideology/ideology_catalog.gd:693-729`).
func _install_on_enter_rows(catalog: Resource, poison_level: int) -> bool:
	if catalog == null:
		return false
	for candidate in catalog.definitions:
		if candidate == null or String(candidate.id) != CARD_KEY:
			continue
		var levels: Array = candidate.levels
		if levels.size() < 2:
			return false
		var l1: Resource = levels[0]
		var l2: Resource = levels[1]
		l1.on_enter_effects = _on_enter_rows(poison_level == 0, false)
		l2.on_enter_effects = _on_enter_rows(poison_level == 1, true)
		return true
	return false


## The exact on-enter list for one level. The clean one-shot lives on level 2.
func _on_enter_rows(poison: bool, clean_oneshot: bool) -> Array[Resource]:
	var rows: Array[Resource] = []
	if clean_oneshot:
		rows.append(_on_enter_row(ONESHOT_COMMAND_KEY, ONESHOT_DEFINITION_KEY))
	if poison:
		rows.append(_on_enter_row(POISON_COMMAND_KEY, POISON_DEFINITION_KEY))
	return rows


## One on-enter modifier APPLY row. `value_mode = 1` (VALUE_STACK_TOP) and
## `duration_days = -1` are the shape every shipped on-enter row uses; `stacks` 1
## keeps the emitted row's `stacks` field equal to the compiled command
## definition's, which `enqueue_external_effect_batch_pod` compares
## (`effect_runtime.cpp:3502-3513`).
func _on_enter_row(command_key: String, definition_key: String) -> Resource:
	var row: Resource = EffectCommandScript.new()
	row.action = 1          # MODIFIER_COMMAND
	row.domain = 1          # ModifierRuntime::COUNTRY
	row.opcode = 1          # ModifierRuntime::COMMAND_APPLY
	row.target_resolver = 1 # TARGET_INSTANCE
	row.value_mode = 1      # VALUE_STACK_TOP
	row.value_q16 = ONESHOT_VALUE_Q16
	row.duration_days = -1
	row.stacks = 1
	row.command_key = StringName(command_key)
	row.definition_key = StringName(definition_key)
	return row


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
## support gate behind `equip` cannot answer without one (`evaluate_support`
## returns `available = false` until `snapshot.revision != 0`).
func _new_world(catalogs: Dictionary, label: String) -> Dictionary:
	# Every world is a fresh runtime, so its business days restart at 0. Reset the
	# fixture counter HERE so no phase can inherit a later day: a runtime day must
	# never go backwards (`ideology_runtime.cpp:5019`, `_last_day < day`).
	_day = 0
	_ran_day = -1
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
		"country_ids": PackedStringArray(["country.pk.%s" % label]),
		"country_names": PackedStringArray(["Pending Keeps Old %s" % label]),
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
		% label, owned == owned_cells.size(),
		"%d vs %d" % [owned, owned_cells.size()])

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
		+ "(household_farmer = political class 'farmer' whose repeal stance for "
		+ "this card is +8192, subsistence_farmer = 'general' whose repeal "
		+ "stance is -8192)") % label,
		farmer_class >= 0 and general_class >= 0,
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
		for pair in [[farmer_class, POP_FARMER], [general_class, POP_GENERAL]]:
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
		% [label, POP_FARMER, POP_GENERAL], bool(eb.get("ok", false)), str(eb))
	var slices := _advance_economy_day(ext, 0, label)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	var support: Dictionary = ext.explain_ideology(handle, int(catalogs["dense"]))
	_print_support("%s (before equip)" % label, support)
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


## The transition receipt `poll_pending_transition` writes when it rolls a card
## back (`append_transition_receipt`, `ideology_runtime.cpp:3754`). It is emitted
## by the runtime itself, not by a command, so it is looked up by reason rather
## than by sequence.
func _transition_receipt(ext: Object, dense: int) -> Dictionary:
	var polled: Dictionary = ext.poll_ideology_receipts(0, 4096)
	var sequences: PackedInt64Array = polled.get("sequences", PackedInt64Array())
	var statuses: PackedInt32Array = polled.get("statuses", PackedInt32Array())
	var opcodes: PackedInt32Array = polled.get("opcodes", PackedInt32Array())
	var reasons: PackedStringArray = polled.get("reasons", PackedStringArray())
	var ideology_ids: PackedInt32Array = polled.get("ideology_ids",
		PackedInt32Array())
	var found := {}
	for i in range(statuses.size()):
		if i >= reasons.size() or String(reasons[i]) != REASON_TRANSITION_REJECTED:
			continue
		if i < ideology_ids.size() and int(ideology_ids[i]) != dense:
			continue
		found = {
			"status": int(statuses[i]),
			"opcode": int(opcodes[i]) if i < opcodes.size() else -1,
			"reason": String(reasons[i]),
			"sequence": int(sequences[i]) if i < sequences.size() else -1,
		}
	return found


# =========================================================================
# advancing
# =========================================================================

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage:
## a single call may come back `done=false` with the day (or the derived rebuild)
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


## Runs the NEXT business day and remembers which one it was, so a settle-day read
## and the following adopt-day read can be described by the day they actually read
## instead of by a magic number. Submits made between two ticks use `_day`, which is
## exactly the day this helper is about to run.
func _tick(ext: Object, label: String) -> bool:
	_ran_day = _day
	var done := _run_one_ideology_day(ext, _day, label)
	_day += 1
	return done


## The production adapter handshake, for the pass that JUST ran. The Effect and
## Modifier domains are driven on the same business day as the ideology pass
## (`world_ext_bind_methods.cpp:635-648`).
func _serve(ext: Object, label: String, expect_clean: bool) -> Dictionary:
	return _serve_native_adapters(ext, _ran_day, label, expect_clean)


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


## True when NO unowned cell carries a contribution (the owned cells are covered
## by the mirror call with `want_owned = true`).
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
## absent rather than 0. Reading it as 0 is the correct interpretation.
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
	print("[PK] program %s (%s): ok=%s magnitude_q16=%s -> %.8f"
		% [program_key, label, str(interp.get("ok", "?")),
			str(interp.get("magnitude", "?")), magnitude])
	return magnitude


# =========================================================================
# printing + bookkeeping
# =========================================================================

func _print_state(tag: String, snap: Dictionary, layer: Dictionary,
		report: Dictionary) -> void:
	print("[PK] %s: locations=%s levels=%s understanding=%s slots_used=%s/%s"
		% [tag, str(snap.get("locations", "?")), str(snap.get("levels", "?")),
			str(snap.get("understanding_q16", "?")),
			str(snap.get("ideology_slots_used", "?")),
			str(snap.get("ideology_slots_capacity", "?"))])
	print("[PK] %s: pending_transitions=%s pending_commands=%s commands_applied=%s "
		% [tag, str(report.get("pending_transitions", "?")),
			str(report.get("pending_commands", "?")),
			str(report.get("commands_applied", "?"))]
		+ "levels_advanced=%s commands_rejected=%s"
		% [str(report.get("levels_advanced", "?")),
			str(report.get("commands_rejected", "?"))])
	print("[PK] %s: front installed=%s cells=%s contributions=%s stats=%s "
		% [tag, str(layer.get("installed", "?")),
			str(layer.get("cell_count", "?")),
			_front_text(layer),
			str(layer.get("stat_count", "?")),]
		+ "generation=%s sample_day=%s"
		% [str(layer.get("layer_generation", "?")),
			str(layer.get("sample_day", "?"))])


## The class-opinion numbers behind the equip support gate, printed rather than
## assumed: `support_q16` / threshold / allowed per direction, plus the influence
## of every class named by the card's stances.
func _print_support(tag: String, explain: Dictionary) -> void:
	var support: PackedInt32Array = explain.get("support_q16", PackedInt32Array())
	print("[PK] %s support: adopt=%s repeal=%s promote=%s (thresholds %s)"
		% [tag, str(support[0] if support.size() > 0 else "?"),
			str(support[SUPPORT_REPEAL_INDEX] if support.size() > 1 else "?"),
			str(support[2] if support.size() > 2 else "?"),
			str(explain.get("support_thresholds_q16", "?"))])
	print("[PK] %s support: allowed=%s available=%s blocking=%s revision=%s"
		% [tag, str(explain.get("support_allowed", "?")),
			str(explain.get("support_available", "?")),
			str(explain.get("support_blocking_classes", "?")),
			str(explain.get("support_revision", "?"))])
	print("[PK] %s support: class_influence=%s repeal_stances=%s"
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
	print("[PK] ---- summary ----")
	for line in _summary:
		print("[PK] %s" % String(line))
	print("[PK] PENDING OUTCOME MEASURED: %s" % _pending_branch)
	print("=== ideology pending keeps the old contribution / rejection leaves no "
		+ "residue / one-shot not replayed: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(0 if _failures == 0 else 1)
