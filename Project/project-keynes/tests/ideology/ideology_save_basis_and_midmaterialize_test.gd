extends SceneTree
## 11.7 time points 5 and 6.
##
##   point 5: "a NEW epoch has already adopted a basis, and THEN the idea changes
##             again"          (22-cell-program-cap-removal-plan-v3.md:805)
##   point 6: "MATERIALIZE is mid-shard and the candidate is NOT installed; only
##             captures that the EXISTING safe boundary acknowledges are allowed"
##                            (22-cell-program-cap-removal-plan-v3.md:806)
##
## THE RULE BOTH POINTS ARE JUDGED BY (same file, line 809):
##
##   at every time point, compare a CONTINUOUS run against the same run after
##   save -> reload, on the per-cell effective factors, the economy conservation
##   result, the one-shot execution counts and the business state. A fresh-world
##   roundtrip on its own does not pass.
##
## This fixture reuses the harness of `ideology_save_before_layer_test.gd`
## (11.7 point 1): same 8x8 world, same scattered 2/3 territory, same card, same
## per-cell probe shape, same comparison helpers. What is NEW is the STATE the
## save is taken in, so three mechanisms had to be established from the C++ first.
##
## ---------------------------------------------------------------------------
## MECHANISM 1 (point 5): what "the epoch adopted a basis" even is
## ---------------------------------------------------------------------------
##
## The derived cell layer is an immutable published front, `DerivedCellFront`
## (`gdext/src/derived_cell_layer.h:79-92`), whose identity is a 6-tuple:
##
##   world_identity, map_generation, generation, sample_day, epoch_id,
##   execution_contract_hash
##
## built in `NativeIdeologyRuntime::step_derived_rebuild` from these members
## (`ideology_runtime.cpp:7051-7053`):
##
##   _derived_world_identity, _derived_map_generation, day, _derived_epoch_id,
##   _execution_contract_hash
##
## FACT ESTABLISHED FROM THE SOURCE (asserted below, not assumed):
## `_derived_world_identity`, `_derived_map_generation` and `_derived_epoch_id`
## are DECLARED (`ideology_runtime.h:1149-1151`) and READ at that one construction
## site, but NO statement anywhere in `gdext/src` assigns them; a whole-tree grep
## for the three names returns only the declaration and the read. Likewise
## `_execution_contract_hash` (`ideology_runtime.h:1058`) is only ever read.
##
## Therefore in THIS build the front's `epoch_id`, `world_identity`,
## `map_generation` and `execution_contract_hash` are structurally 0, and
## `get_derived_cell_layer_report()["epoch_id"]` (`world_ext_modifier.cpp:1142`)
## cannot distinguish one epoch from another. The only basis markers that carry
## information are `generation` (bumped by every successful install, exported as
## `layer_generation`, `world_ext_modifier.cpp:1080-1081`) and `sample_day` (the
## day the last install was BUILT for, `:1141`).
##
## So "the epoch adopted a basis" is proven by what the runtime really does: a new
## economy input epoch is opened for a new day and commits to its boundary
## (`begin_or_reuse_economy_input_epoch`, `world_ext_economy.cpp:655`), the
## derived rebuild for that day runs to completion (`derived_rebuild_pending ==
## false`, `cell_layer_rebuild_steps >= 2` = one collect step + one fold step), and
## the front is INSTALLED and serving every covered cell.
##
## THE IDEA CHANGE, and why it can only be a LEVEL change here:
##
##   * a LEVEL change is the change that alters the derived CONTENT -- but only
##     once it is CONFIRMED. The collector serves
##     `_levels[level_begin + contribution_level]`
##     (`ideology_runtime.cpp:2322-2332`), and since the plan 10.1 rework
##     `contribution_level` is `transition.previous_level` while a transition is
##     in flight (`:2316-2321`). So `state.level` advancing at REQUEST time no
##     longer moves the front; the NEXT ACKED level does. `public_hygiene_l1` is
##     CONST 3277 (birth factor +5%, housing cut 8%) and `public_hygiene_l2` is
##     CONST 5243 / 6554 (+8% / 10%) -- `data/ideologies/
##     default_ideology_effects.tres:5336-5468`. The change is therefore visible
##     cell by cell AND has an absolute expected value, one settle after the
##     level itself moved.
##
##   * UNEQUIP (`UNEQUIP_IDEOLOGY = 6`, `ideology_runtime.h:72`) is NOT usable
##     after the equip: `start_transition` leaves the equip's own transition
##     pending until the Effect runtime ACKs its level commands
##     (`ideology_runtime.cpp:3536-3727`), and both `equip` (`:4550-4555`) and
##     `unequip` (`:4576-4581`) refuse while `pending_transition_count > 0` or
##     `state->transition.active != 0`. Measured on the first attempt: the day-3
##     unequip was rejected and the front never changed. That rejection is not a
##     fixture bug -- it is why the fixture has to serve the native adapters
##     (below) before any further idea command can land.
##
##   * `start_next_level_transition` (`:3814-3828`) is also the reason the level
##     cannot move while the equip transition is still pending (`:3816` returns
##     early). So the pending transition MUST be settled first.
##
## Serving it is a production path, not a test trick: the native Effect adapters
## are dispatched and acked by the daily graph
## (`dispatch_effect_native_modifier` / `ack_effect_native_modifier`,
## `world_ext_effect.cpp:905-929` -> `EffectRuntime::dispatch_native_modifier`
## `effect_runtime.cpp:5488`, which submits the ideology rows with
## `adapter_kind == NATIVE_MODIFIER_IDEOLOGY`, `:5659`). The next
## `run_ideology_daily` slice polls `_pending_transitions` first
## (`ideology_runtime.cpp:4954-4968`) and settles the transition.
##
## AND THE SETTLE MUST BE FOLLOWED BY A REBUILD OF THE SAME DAY. The collect step
## of a day runs at the END of the slice that applied the command, i.e. BEFORE the
## ACK could exist (`step_derived_rebuild` collects once per day, `:7042-7059`);
## an in-flight job is never re-collected. So it is not enough to ACK and read:
## once the transition is settled, one more pass over that day is what collects
## the CONFIRMED basis and publishes it. Both time points do exactly that (see the
## `settle` passes below), and neither ever moves the day index BACKWARDS.
##
## ---------------------------------------------------------------------------
## MECHANISM 2 (point 6): how a fixture stops MATERIALIZE between slices
## ---------------------------------------------------------------------------
##
## The rebuild is a SLICE STAGE: `run_daily_slices` calls `step_derived_rebuild`
## once per `run_ideology_daily` (`ideology_runtime.cpp:5047-5054`) and does ONE
## kind of work per call (`:6978-7109`):
##
##   collect slice - gathers the contributions and CONSTRUCTS the job
##                   (`_derived_rebuild_job.reset(new ...)`, `:7051`), then returns
##                   false (`:7054`). NOTHING is installed.
##   fold slice(s) - `fold_step` with a time budget (`:7059`); while it returns
##                   false the call returns false (`:7067`) and nothing is
##                   installed. Only when it returns true does `finish()` build the
##                   candidate and `install_derived_cell_layer` swap it in
##                   (`:7069-7104`).
##
## `derived_rebuild_pending()` is `_derived_rebuild_day >= 0`
## (`ideology_runtime.h:182-184`), i.e. "a build is in flight for this day".
## `drain_derived_cell_layer` (`world_ext_modifier.cpp:961-983`) loops that stage to
## completion and is therefore the WRONG tool for stopping half way. A fixture
## stops mid-way by pumping `run_ideology_daily` ONE SLICE AT A TIME and stopping
## on the slice that reports
##
##   stage == "ideology_derived_rebuild"   (the `finish` lambda, `:4899-4917`)
##   done  == false
##   cell_layer_rebuild_steps == 1          (`_derived_rebuild_steps =
##                                           ++_derived_rebuild_slices`, `:7033`)
##   derived_rebuild_pending == true
##
## `cell_layer_rebuild_steps == 1` makes the stop UNAMBIGUOUS: the counter is NOT
## reset when the day changes (`:6991-7004` resets `_derived_rebuild_slices` but
## leaves `_derived_rebuild_steps`), so a stale value from the previous day could
## otherwise fake the same state. The first collect of a day sets it to exactly 1.
##
## ---------------------------------------------------------------------------
## MECHANISM 3: the save/restore ORDER, which this harness cannot skip
## ---------------------------------------------------------------------------
##
## PKID alone cannot be restored into a fresh runtime once the save contains an
## ACTIVE idea. `restore` verifies, for every active idea, that the Effect runtime
## still holds the durable binding it names
## (`ideology_runtime.cpp:6793-6812`: binding id, binding generation, binding
## signature, catalog hash and `has_external_binding_pod`), and rejects the whole
## payload with `ideology_effect_binding_missing_or_mismatched` otherwise -- the
## rollback is total (measured: the reloaded world kept `locations=[]`).
##
## That is an ORDERING assertion, and the runtime says so at `:6748-6751`
## ("PKEF restores first (game_save_coordinator)"). This fixture therefore saves
## and restores the pair the coordinator uses
## (`scripts/game/game_save_coordinator.gd:10,967,1154`):
##
##   capture: `capture_effect_state()`  then `capture_ideology_state()`
##   restore: `restore_effect_state()`  then `restore_ideology_state()`
##
## ---------------------------------------------------------------------------
## THE SAFE BOUNDARY (plan line 806: "only captures the existing safe boundary acknowledges")
## ---------------------------------------------------------------------------
##
## The production gate is `GameSaveCoordinator._can_save()`
## (`scripts/game/game_save_coordinator.gd:351-422`). For ideology it asks exactly
## one question (`:416-421`):
##
##   if ideology_ext.ideology_should_run(day): -> "save_requires_idle_ideology"
##
## and `NativeIdeologyRuntime::should_run` (`ideology_runtime.cpp:5057-5068`) has
## terms for pending commands, pending transitions, active progress, `_last_day`
## and the managed-instance refresh -- but NO term for `derived_rebuild_pending()`.
## The capture itself has no guard either: `capture()` (`:6393-6499`) writes
## catalog hash, day, submit order, state hash, high watermarks, points revision,
## country rows, ideas, offers and pending commands. The in-flight job, its
## contributions and the installed front are NOT in the payload.
##
## This fixture MEASURES the boundary instead of assuming it: it calls
## `ideology_should_run(mid_day)` at the mid-materialize instant, records the
## verdict, and then reports whether the capture was permitted.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_basis_and_midmaterialize_test.gd

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
## `LevelPublicHygieneL2.understanding_threshold_q16` in
## `data/ideologies/default_ideology_catalog.tres`: the level-1 threshold.
const L2_THRESHOLD_Q16 := 524288
## Opcodes out of `ideology_runtime.h:66-79`.
const OP_DISCOVER := 1
const OP_GRANT := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

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

	var tp5: Dictionary = _run_time_point_5(_tp5_batches(dense))
	var tp6: Dictionary = _run_time_point_6(_tp6_batches(dense))
	_negative_control(tp5, tp6)
	_applied_basis_control(tp5)
	_scalar_basis_control(tp5)
	_finish()


# =========================================================================
# point 5 -- basis adopted by a new epoch, then the idea changes
# =========================================================================

## Timeline (identical calls on both sides; only the save/reload boundary differs):
##
##   world        economy day 0 (epoch 1) and day 1 (epoch 2) are committed with NO
##                card in play, so both worlds bootstrap bit-identically and no
##                economy day ever runs with a different front on the two sides.
##   ideology d0  the equip applies, but its level transaction is PENDING, so
##                plan 10.1 makes it contribute NOTHING and day 0's rebuild
##                publishes an EMPTY front.
##   adapters     the native Effect adapters are served, which is what lets the
##                equip's own level transaction reach ACKED.
##   d0 settle    ONE more pass over day 0: it POLLS the pending transition and
##                SETTLES it (day 0's commands are already consumed, its daily
##                understanding accrual is guarded by `_last_day < day`). The
##                settle records confirmed_day 0 / eligible_from_day 1, so this
##                pass is REFUSED by the plan §9.3 eligibility gate and publishes
##                NOTHING: "confirmed but not yet eligible", asserted as its own
##                state.
##   ideology d1  THE ELIGIBILITY DAY, and the new epoch's day. Its rebuild is the
##                first one allowed to adopt the confirmed projection, so it
##                INSTALLS the LEVEL-0 content for sample_day 1 -- basis adopted.
##   d1 again     a second pass over day 1 (legal re-entry, nothing accrues twice).
##                The rebuild is content-identical to the adopted basis, so the
##                install is skipped (I13) and `pending_transitions` stays 0.
##   SAVE         ADD_UNDERSTANDING(L2 threshold) is queued for day 3: THE IDEA
##                CHANGE, not yet applied. Save PKEF + PKID.
##   d2           still pending: understanding below the threshold, level 0, the
##                front still carries the LEVEL 0 magnitudes.
##   d3           the change lands: `start_next_level_transition` sets
##                `state.level = 1`, but the level-up's Effect transactions are
##                NOT ACKed yet, so plan 10.1 keeps serving the PREVIOUS level and the
##                front still carries the LEVEL 0 magnitudes.
##   adapters     the level-up's native Effect adapters are served.
##   d4           the poll SETTLES the level-up: confirmed_day 4,
##                eligible_from_day 5. The day's rebuild is refused by §9.3, so the
##                front still serves the LEVEL-0 magnitudes. Asserted: a second
##                "confirmed but not eligible" state, this time with a REAL
##                previous front in force.
##   d5           the level-up's eligibility day: the rebuild collects the
##                CONFIRMED level 1 and INSTALLS the LEVEL-1 magnitudes for
##                sample_day 5. Stable from here.
func _run_time_point_5(batches: Array) -> Dictionary:
	print("[sv5] ---- time point 5: basis adopted by a new epoch, then the idea changes ----")
	var cont: Dictionary = _new_world("tp5-continuous", 2)
	var ext: Object = cont["ext"]
	var handle: int = int(cont["handle"])
	var owned: int = int(cont["owned"])
	var expect_cells: int = 2 * owned

	# -- the epochs that precede the basis -------------------------------
	var epoch1: Dictionary = cont["epoch1"]
	var epoch2: Dictionary = cont["epoch2"]
	_expect("tp5: epoch 1 (day 0) is opened and committed before any card exists",
		bool(epoch1.get("ok", false)) and not bool(cont["epoch_active"]),
		"ok=%s epoch_active=%s" % [str(epoch1.get("ok", "?")),
			str(cont["epoch_active"])])
	_expect("tp5: a SECOND epoch (day 1, epoch_id=2) is opened and committed",
		bool(epoch2.get("ok", false)) and bool(epoch2.get("captured", false)),
		"ok=%s captured=%s reused=%s reason=%s" % [
			str(epoch2.get("ok", "?")), str(epoch2.get("captured", "?")),
			str(epoch2.get("input_capture_reused", "?")),
			str(epoch2.get("reason", epoch2.get("fatal_reason", "")))])
	_expect("tp5: the new epoch's day is committed before the basis is adopted",
		not bool(cont["epoch_active"])
		and int(cont["newest_state_day"]) == 1,
		"epoch_active=%s newest_state_day=%s" % [str(cont["epoch_active"]),
			str(cont["newest_state_day"])])

	# -- the card equips under the new epoch; the front installs ---------
	_submit(ext, batches[0], handle)   # grant points
	_submit(ext, batches[1], handle)   # discover
	_submit(ext, batches[2], handle)   # equip (effective day 0)
	_run_one_ideology_day(ext, 0, "tp5/cont")

	# Plan 10.1 AS IMPLEMENTED: between the equip's REQUEST and its ACK the card
	# contributes NOTHING, so day 0's rebuild publishes no front at all. Asserted
	# rather than assumed -- this is the state the settle pass below has to change.
	var pre_settle: Dictionary = ext.get_derived_cell_layer_report()
	_expect("tp5: while the equip transition is PENDING the card contributes "
		+ "NOTHING (no front installed, generation 0)",
		not bool(pre_settle.get("installed", true))
		and int(pre_settle.get("layer_generation", -1)) == 0
		and int(pre_settle.get("cell_count", -1)) == 0,
		"installed=%s generation=%s cells=%s" % [
			str(pre_settle.get("installed", "?")),
			str(pre_settle.get("layer_generation", "?")),
			str(pre_settle.get("cell_count", "?"))])

	# -- settle the equip's level transaction (production adapter path) ---
	#
	# THE ORDERING THIS FIXTURE HAD TO MOVE, TWICE OVER (plan 10.1 and §9.3).
	#
	# (1) plan 10.1: a card whose EQUIP transition is not ACKed contributes
	#     NOTHING -- `collect_effect_activations` returns early while
	#     `transition.previous_location == INACTIVE` (`ideology_runtime.cpp:2317-2318`)
	#     -- so the rebuild day 0 just folded published an EMPTY front, because its
	#     COLLECT step ran while the equip was still pending.
	# (2) plan §9.3: once the ACK is polled, the day it is polled on becomes the
	#     projection's `confirmed_day`, its `eligible_from_day` is the day AFTER,
	#     and `step_derived_rebuild` REFUSES to adopt while
	#     `day < eligible_from_day` (`ideology_runtime.cpp:7045-7048`). So day 0's
	#     settle pass cannot publish either: it CONFIRMS the projection and is
	#     counted in `derived_rebuild_gated_by_eligibility`.
	#
	# Serving the native adapters is the production path (the daily graph does
	# exactly this every day). Re-entering the SAME day is what turns the ACK into
	# a settlement (`:4954-4968` polls `_pending_transitions` first), and the next
	# day -- the eligibility day -- is the first rebuild allowed to publish it.
	# Nothing is re-done by either pass: day 0's commands were consumed and the
	# queue cleared (`:5001-5004`), its daily understanding accrual is guarded by
	# `_last_day < day` (`:5019`), and point settlement is keyed by the committed
	# economy day (`accrue_points`). The day index never moves BACKWARDS -- a
	# backwards day would leave `_last_day < day` false and silently skip the day's
	# work.
	var served: Dictionary = _serve_native_adapters(ext, 0, "tp5")
	_expect("tp5: the native Effect adapters accepted and ACKED the equip's "
		+ "level commands",
		bool(served.get("ok", false)) and bool(served.get("effect_acked", false)),
		str(served))
	_run_one_ideology_day(ext, 0, "tp5/cont/settle")
	var settled0: Dictionary = ext.get_ideology_report()
	_expect("tp5: the equip's transition is SETTLED after the settle pass "
		+ "(pending_transitions == 0)",
		int(settled0.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(settled0.get("pending_transitions", "?")))

	# -- the state §9.3 creates: CONFIRMED on day 0, publishable on day 1 ---
	#
	# This is a real, assertable state and the reason the fixture now has an extra
	# time point: plan §11.7 lists "confirmed but not yet at the eligibility day",
	# and :719 requires the save to be able to say which projections are not
	# eligible yet. The front is STILL the previous one (here: none at all).
	_expect("tp5: the equip's projection is CONFIRMED on day 0 and eligible only "
		+ "from day 1",
		int(settled0.get("derived_basis_confirmed_day", -1)) == 0
			and int(settled0.get("derived_basis_eligible_day", -1)) == 1,
		"confirmed=%s eligible=%s" % [
			str(settled0.get("derived_basis_confirmed_day", "?")),
			str(settled0.get("derived_basis_eligible_day", "?"))])
	_expect("tp5: day 0's rebuild was REFUSED by the eligibility gate "
		+ "(derived_rebuild_gated_by_eligibility > 0)",
		int(settled0.get("derived_rebuild_gated_by_eligibility", 0)) > 0,
		"gated=%s" % str(settled0.get(
			"derived_rebuild_gated_by_eligibility", "?")))
	var confirmed_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("tp5: the confirmation day publishes NOTHING (the previous front is "
		+ "still the one in force -- here it is the empty one)",
		not bool(confirmed_layer.get("installed", true))
			and int(confirmed_layer.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [
			str(confirmed_layer.get("installed", "?")),
			str(confirmed_layer.get("cell_count", "?"))])
	print("[sv5] confirmed-not-eligible: confirmed_day=%s eligible_from_day=%s "
		% [str(settled0.get("derived_basis_confirmed_day", "?")),
			str(settled0.get("derived_basis_eligible_day", "?"))]
		+ "gated=%s front installed=%s cells=%s sample_day=%s"
		% [str(settled0.get("derived_rebuild_gated_by_eligibility", "?")),
			str(confirmed_layer.get("installed", "?")),
			str(confirmed_layer.get("cell_count", "?")),
			str(confirmed_layer.get("sample_day", "?"))])

	# -- the eligibility day: the first rebuild allowed to adopt the basis --
	_run_one_ideology_day(ext, 1, "tp5/cont/eligible")
	var drained_eligible: Dictionary = ext.drain_derived_cell_layer(1)
	_expect("tp5: the eligibility day's rebuild folds to completion",
		bool(drained_eligible.get("complete", false)), str(drained_eligible))

	var layer0: Dictionary = ext.get_derived_cell_layer_report()
	var gen_after_install := int(layer0.get("layer_generation", -1))
	_expect("tp5: the front INSTALLS on the eligibility day (basis adopted)",
		bool(layer0.get("installed", false)) and gen_after_install >= 1,
		"installed=%s generation=%s sample_day=%s" % [
			str(layer0.get("installed", "?")), str(gen_after_install),
			str(layer0.get("sample_day", "?"))])
	# §9.3: the front is built FOR the day it was allowed to be built on, so its
	# `sample_day` is the projection's eligibility day, not the confirmation day.
	_expect("tp5: the adopted front is built FOR the eligibility day "
		+ "(sample_day == 1, not the confirmation day 0)",
		int(layer0.get("sample_day", -1)) == 1,
		"sample_day=%s" % str(layer0.get("sample_day", "?")))
	_expect("tp5: the adopted basis covers exactly the owned cells x 2 stats",
		int(layer0.get("cell_count", -1)) == expect_cells
		and int(layer0.get("contribution_count", -1)) == expect_cells
		and int(layer0.get("stat_count", -1)) == 2,
		"cells=%s contributions=%s stats=%s expected=%d" % [
			str(layer0.get("cell_count", "?")),
			str(layer0.get("contribution_count", "?")),
			str(layer0.get("stat_count", "?")), expect_cells])

	# -- a SECOND rebuild on the same day re-materialises the same basis ---
	# Re-entering the eligibility day is legal (`_last_day < day` is false, so
	# nothing accrues twice) and is the honest way to show the rebuild is
	# idempotent: same input, same contributions, no install.
	var report_before_day1: Dictionary = ext.get_ideology_report()
	var visits_before := int(report_before_day1.get("cell_layer_rebuild_visits", 0))
	_run_one_ideology_day(ext, 1, "tp5/cont")
	var drained1: Dictionary = ext.drain_derived_cell_layer(1)
	var report_day1: Dictionary = ext.get_ideology_report()
	var layer1: Dictionary = ext.get_derived_cell_layer_report()
	_expect("tp5: the new epoch's day drives the derived rebuild",
		int(report_day1.get("cell_layer_rebuild_visits", 0)) > visits_before,
		"visits %d -> %s" % [visits_before,
			str(report_day1.get("cell_layer_rebuild_visits", "?"))])
	_expect("tp5: the new epoch's rebuild runs to completion (nothing left pending)",
		bool(drained1.get("complete", false))
		and not bool(report_day1.get("derived_rebuild_pending", true))
		and int(report_day1.get("cell_layer_rebuild_steps", 0)) >= 2,
		"drained=%s pending=%s steps=%s" % [str(drained1),
			str(report_day1.get("derived_rebuild_pending", "?")),
			str(report_day1.get("cell_layer_rebuild_steps", "?"))])
	# The settled basis: the equip's level transaction reached ACKED, so the epoch
	# holds a completed basis rather than a half-confirmed one.
	_expect("tp5: the adopted basis is SETTLED (no transition left in flight)",
		int(report_day1.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report_day1.get("pending_transitions", "?")))
	# I13: identical content does not re-install, so `generation` does not move.
	_expect("tp5: an identical rebuild does NOT bump the layer generation (I13)",
		int(layer1.get("layer_generation", -1)) == gen_after_install,
		"%d -> %s" % [gen_after_install, str(layer1.get("layer_generation", "?"))])
	# THE STRUCTURAL FACT, asserted rather than hidden in a comment.
	_expect("tp5: layer epoch_id is structurally 0 in this build "
		+ "(member never assigned; not usable as a basis marker)",
		int(layer1.get("epoch_id", -1)) == 0,
		"epoch_id=%s (declared ideology_runtime.h:1149-1151, only read at "
			% str(layer1.get("epoch_id", "?"))
		+ "ideology_runtime.cpp:7052-7053)")

	# -- the idea changes: the LEVEL-1 threshold is queued for day 3 -----
	var before_change: Dictionary = _capture_state(cont, "tp5-cont/day1", true, 1,
		PROGRAM_L1)
	_expect("tp5: before the change the card is at level 0",
		str(before_change["snapshot"]["levels"]) == str(PackedInt32Array([0])),
		str(before_change["snapshot"]["levels"]))
	_expect("tp5: before the change the understanding is below the level-1 threshold",
		(before_change["snapshot"]["understanding_q16"] as PackedInt64Array)[0]
			< L2_THRESHOLD_Q16,
		"%d vs %d" % [(before_change["snapshot"]["understanding_q16"]
			as PackedInt64Array)[0], L2_THRESHOLD_Q16])

	_submit(ext, batches[3], handle)   # ADD_UNDERSTANDING(L2 threshold), day 3
	var at_save_report: Dictionary = ext.get_ideology_report()
	var at_save: Dictionary = _capture_state(cont, "tp5-cont/save", true, 1, PROGRAM_L1)
	_expect("tp5: the idea change is QUEUED and not applied at save time",
		int(at_save_report.get("pending_commands", -1)) == 1,
		"pending_commands=%s" % str(at_save_report.get("pending_commands", "?")))
	_expect("tp5: no derived rebuild is in flight at the save boundary",
		not bool(at_save_report.get("derived_rebuild_pending", true)),
		str(at_save_report.get("derived_rebuild_pending", "?")))
	_expect("tp5: the card is still equipped at save time",
		_active_locations(at_save["snapshot"]) > 0,
		str(at_save["snapshot"]["locations"]))
	var save_gen := int(at_save["layer_generation"])
	var save_cells := int(at_save["layer"]["cell_count"])
	_expect("tp5: the save carries the installed, still-serving front",
		save_cells == expect_cells and save_gen == gen_after_install,
		"cells=%d generation=%d" % [save_cells, save_gen])
	var saved: Dictionary = _capture_pair(ext, "tp5/SAVE")
	at_save["save"] = saved

	# -- continuous: day 2 (unchanged), day 3 (change lands), day 4 ------
	_advance_economy_day(ext, 2, "tp5/cont")
	_run_one_ideology_day(ext, 2, "tp5/cont")
	var cont_day2: Dictionary = _capture_state(cont, "tp5-cont/day2", true, 2,
		PROGRAM_L1)
	_expect("tp5: the queued change has NOT been applied by day 2 (continuous)",
		int(cont_day2["snapshot"]["pending_commands"]) == 1
		and int(cont_day2["layer"]["cell_count"]) == expect_cells
		and str(cont_day2["snapshot"]["levels"]) == str(PackedInt32Array([0])),
		"pending=%d levels=%s" % [
			int(cont_day2["snapshot"]["pending_commands"]),
			str(cont_day2["snapshot"]["levels"])])

	_advance_economy_day(ext, 3, "tp5/cont")
	_run_one_ideology_day(ext, 3, "tp5/cont")
	# THE LEVEL MOVES HERE; THE CONTENT DOES NOT -- yet. `start_next_level_transition`
	# writes `state.level = 1` at REQUEST time, and plan 10.1 keeps serving the OLD
	# basis while the transition is pending ("a level-up keeps the old level"). The
	# collector now implements that by reading `transition.previous_level`
	# (`ideology_runtime.cpp:2316-2321`), so day 3's front still carries the LEVEL-0
	# magnitudes and the level-1 program can only be published after the level-up's
	# Effect transactions are ACKed. Hence `PROGRAM_L1` here, not `PROGRAM_L2`.
	var cont_day3: Dictionary = _capture_state(cont, "tp5-cont/day3", true, 3,
		PROGRAM_L1)
	_expect("tp5: the idea change LANDS on day 3 (continuous): level 1, command applied",
		str(cont_day3["snapshot"]["levels"]) == str(PackedInt32Array([1]))
		and int(cont_day3["snapshot"]["pending_commands"]) == 0,
		"levels=%s pending=%s" % [
			str(cont_day3["snapshot"]["levels"]),
			str(cont_day3["snapshot"]["pending_commands"])])
	_expect("tp5: while the level-up transition is PENDING the front still serves "
		+ "the PREVIOUS level's magnitudes (plan 10.1: the pending window keeps the "
		+ "old basis)",
		absf(_covered_add(cont_day3) - _covered_add(cont_day2)) < 1e-12
		and int(cont_day3["snapshot"]["pending_transitions"]) == 1,
		"add %.8f -> %.8f pending_transitions=%s" % [
			_covered_add(cont_day2), _covered_add(cont_day3),
			str(cont_day3["snapshot"]["pending_transitions"])])

	# -- settle the level-up, THEN read the derived layer ----------------
	#
	# The same two-step settle the equip needed on day 0, one step per plan:
	#   day 4  serve the adapters, then let the poll settle the transition
	#          (`:4954-4968`). That confirms it (confirmed_day == 4,
	#          eligible_from_day == 5, `ideology_runtime.cpp:3845-3846`) and the
	#          §9.3 gate REFUSES the day's rebuild (`:7045-7048`): the front still
	#          serves the previous level.
	#   day 5  the eligibility day. The rebuild collects the CONFIRMED level and
	#          publishes it. This is where the content change becomes observable --
	#          two days after the level itself moved, and one day later than the
	#          ACK, because §9.3 never adopts a projection on its confirmation day.
	_serve_native_adapters(ext, 3, "tp5/levelup")
	_advance_economy_day(ext, 4, "tp5/cont")
	_run_one_ideology_day(ext, 4, "tp5/cont")
	var cont_day4: Dictionary = _capture_state(cont, "tp5-cont/confirmed", true, 4,
		PROGRAM_L1)
	var cont_day4_report: Dictionary = ext.get_ideology_report()
	_expect("tp5: the level-up is CONFIRMED on day 4 and only eligible from day 5",
		int(cont_day4_report.get("derived_basis_confirmed_day", -1)) == 4
			and int(cont_day4_report.get("derived_basis_eligible_day", -1)) == 5,
		"confirmed=%s eligible=%s" % [
			str(cont_day4_report.get("derived_basis_confirmed_day", "?")),
			str(cont_day4_report.get("derived_basis_eligible_day", "?"))])
	_expect("tp5: the confirmation day's rebuild is REFUSED by the eligibility gate "
		+ "(the level-1 content is NOT published a day early)",
		int(cont_day4_report.get("derived_rebuild_gated_by_eligibility", 0)) > 0
		and int(cont_day4["layer"]["sample_day"]) == 1
		and absf(_covered_add(cont_day4) - _covered_add(cont_day3)) < 1e-12,
		"gated=%s sample_day=%s add %.8f vs %.8f" % [
			str(cont_day4_report.get("derived_rebuild_gated_by_eligibility", "?")),
			str(cont_day4["layer"]["sample_day"]),
			_covered_add(cont_day4), _covered_add(cont_day3)])
	print("[sv5] level-up confirmed-not-eligible: confirmed_day=%s "
		% str(cont_day4_report.get("derived_basis_confirmed_day", "?"))
		+ "eligible_from_day=%s gated=%s front sample_day=%s add=%.8f"
		% [str(cont_day4_report.get("derived_basis_eligible_day", "?")),
			str(cont_day4_report.get("derived_rebuild_gated_by_eligibility", "?")),
			str(cont_day4["layer"]["sample_day"]), _covered_add(cont_day4)])
	_advance_economy_day(ext, 5, "tp5/cont")
	_run_one_ideology_day(ext, 5, "tp5/cont")
	var cont_final: Dictionary = _capture_state(cont, "tp5-cont/final", true, 5,
		PROGRAM_L2)
	_expect("tp5: after the level-up is ACKED and ELIGIBLE the front publishes the "
		+ "LEVEL-1 magnitudes (observable on the eligibility day, not on day 3)",
		int(cont_final["snapshot"]["pending_transitions"]) == 0
		and absf(_covered_add(cont_final) - _covered_add(cont_day3)) > 0.02,
		"add %.8f -> %.8f pending_transitions=%s" % [
			_covered_add(cont_day3), _covered_add(cont_final),
			str(cont_final["snapshot"]["pending_transitions"])])
	_expect("tp5: the level-1 front is built FOR the eligibility day (sample_day 5)",
		int(cont_final["layer"]["sample_day"]) == 5,
		"sample_day=%s" % str(cont_final["layer"]["sample_day"]))

	# -- reload of the same save, in the coordinator's section order -----
	var reload: Dictionary = _new_world("tp5-reload", 2)
	var rext: Object = reload["ext"]
	var r_ok: Dictionary = _restore_pair(rext, saved, "tp5")
	_expect("tp5: the PKEF+PKID pair restores into a freshly built runtime",
		bool(r_ok.get("ok", false)), str(r_ok.get("reason", r_ok)))
	var r_handle: int = int(reload["handle"])
	_expect("tp5: the reloaded world resolves the same country handle",
		r_handle == handle, "%d vs %d" % [r_handle, handle])

	var r_report: Dictionary = rext.get_ideology_report()
	var r_layer: Dictionary = rext.get_derived_cell_layer_report()
	_expect("tp5: the idea change is STILL PENDING right after reload "
		+ "(not silently applied early)",
		int(r_report.get("pending_commands", -1)) == 1,
		"pending=%s" % str(r_report.get("pending_commands", "?")))
	var r_business: Dictionary = rext.get_ideology_business_state()
	_expect("tp5: the restored business state is byte-identical to the saved one",
		int(r_business.get("hash", 0)) == int(at_save["business"].get("hash", -1)),
		"%s vs %s" % [str(r_business.get("hash", "?")),
			str(at_save["business"].get("hash", "?"))])
	_expect("tp5: PKID carries NO front, so a fresh runtime starts without one",
		not bool(r_layer.get("installed", true))
		and int(r_layer.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [str(r_layer.get("installed", "?")),
			str(r_layer.get("cell_count", "?"))])
	var r_snap: Dictionary = rext.get_ideology_snapshot(r_handle)
	_expect("tp5: the card is still equipped at level 0 after reload",
		str(r_snap.get("locations", PackedInt32Array())) == str(PackedInt32Array([1]))
		and str(r_snap.get("levels", PackedInt32Array())) == str(PackedInt32Array([0])),
		"locations=%s levels=%s" % [str(r_snap.get("locations", "?")),
			str(r_snap.get("levels", "?"))])

	# -- reload continuation, same order as the continuous branch -------
	_advance_economy_day(rext, 2, "tp5/reload")
	_run_one_ideology_day(rext, 2, "tp5/reload")
	var r_day2: Dictionary = _capture_state(reload, "tp5-reload/day2", true, 2,
		PROGRAM_L1)
	_expect("tp5: the queued change has NOT been applied by day 2 (reload)",
		int(r_day2["snapshot"]["pending_commands"]) == 1
		and int(r_day2["layer"]["cell_count"]) == expect_cells
		and str(r_day2["snapshot"]["levels"]) == str(PackedInt32Array([0])),
		"pending=%d levels=%s" % [
			int(r_day2["snapshot"]["pending_commands"]),
			str(r_day2["snapshot"]["levels"])])

	_advance_economy_day(rext, 3, "tp5/reload")
	_run_one_ideology_day(rext, 3, "tp5/reload")
	# The SAME pending window as the continuous run: the level has moved to 1, the
	# un-ACKed level-up still serves the previous level's content.
	var r_day3: Dictionary = _capture_state(reload, "tp5-reload/day3", true, 3,
		PROGRAM_L1)

	# The same settle, at the same day index, so the two sides still differ only in
	# the save/reload boundary: day 4 confirms and is refused, day 5 publishes.
	_serve_native_adapters(rext, 3, "tp5/reload-levelup")
	_advance_economy_day(rext, 4, "tp5/reload")
	_run_one_ideology_day(rext, 4, "tp5/reload")
	var r_day4: Dictionary = _capture_state(reload, "tp5-reload/confirmed", true, 4,
		PROGRAM_L1)
	_advance_economy_day(rext, 5, "tp5/reload")
	_run_one_ideology_day(rext, 5, "tp5/reload")
	var r_final: Dictionary = _capture_state(reload, "tp5-reload/final", true, 5,
		PROGRAM_L2)

	# -- the comparisons -------------------------------------------------
	# (a) BEFORE the change lands: the front the continuous run built on the equip's
	# eligibility day must be reproduced cell for cell by the front the reload built
	# on day 2. The install DAYS differ on purpose (the save carries no front), which
	# is why `_compare` does not compare `sample_day`.
	_compare(cont_day2, r_day2, "tp5/day2", 1)
	# (b) the change lands on the same day on both sides, with the same content.
	_expect("tp5: the idea change applies on the SAME DAY in both runs "
		+ "(level 0 on day 2, level 1 on day 3)",
		str(cont_day3["snapshot"]["levels"]) == str(r_day3["snapshot"]["levels"])
		and str(cont_day3["snapshot"]["levels"]) == str(PackedInt32Array([1]))
		and absf(_covered_add(cont_day3) - _covered_add(r_day3)) < 1e-12,
		"levels %s/%s add %.8f/%.8f" % [
			str(cont_day3["snapshot"]["levels"]),
			str(r_day3["snapshot"]["levels"]),
			_covered_add(cont_day3), _covered_add(r_day3)])
	_compare(cont_day3, r_day3, "tp5/day3", 0)
	# (c) the confirmation day: both sides publish NOTHING new (the §9.3 gate), and
	# they agree on the front that is still in force.
	_compare(cont_day4, r_day4, "tp5/confirmed", 0)
	_compare(cont_final, r_final, "tp5/final", 0)
	_expect("tp5: both runs rebuilt the front on the same day after the change",
		int(cont_final["layer"]["sample_day"]) == int(r_final["layer"]["sample_day"])
		and int(cont_final["layer"]["sample_day"]) == 5,
		"%s vs %s (the level-up's eligibility day)" % [
			str(cont_final["layer"]["sample_day"]),
			str(r_final["layer"]["sample_day"])])

	return {"final": cont_final, "save_bytes": saved.get("pkid", PackedByteArray()),
		"level_change": true, "ext": ext,
		# §18.5: what the projection looked like AT THE SAVE BOUNDARY. The sample day
		# moved on afterwards (the final front is built for day 5), so the payload's
		# day has to be compared with these, not with `final`.
		"at_save_report": at_save_report,
		"at_save_layer_day": int(at_save["layer"].get("sample_day", -2))}


## Point-5 batches. Fixed sequences, submitted identically to every branch;
## `sequences` is the idempotency key and the high watermark is part of PKID.
func _tp5_batches(dense: int) -> Array:
	return [
		_batch(OP_GRANT, 0, -1, 64 * Q16_ONE, 1),          # points
		_batch(OP_DISCOVER, 0, dense, 0, 2),               # the card
		_batch(OP_EQUIP, 0, dense, 0, 3),                  # equip, effective day 0
		_batch(OP_ADD_UNDERSTANDING, 3, dense, L2_THRESHOLD_Q16, 4),  # THE CHANGE
	]


# =========================================================================
# point 6 -- mid-materialize, candidate not installed
# =========================================================================

## Timeline:
##
##   ideology d0  the equip applies; its transition is PENDING, so plan 10.1 makes it
##                contribute nothing and day 0's rebuild publishes an empty front.
##   adapters     the equip's level transaction is settled (production adapters).
##   d0 settle    ONE more pass over day 0 polls the ACK and SETTLES the transition.
##                Plan §9.3 then refuses that day's rebuild (confirmed 0, eligible
##                1), so nothing is published: asserted as the "confirmed but not
##                eligible" state.
##   ideology d1  the ELIGIBILITY day, and the first rebuild allowed to adopt. It
##                installs the OLD front (generation 1, sample_day 1) that the
##                mid-materialize candidate of the same day must keep serving.
##   d1 again     the rebuild is pumped SLICE BY SLICE and the fixture STOPS on
##                the collect slice: `derived_rebuild_pending == true`,
##                `cell_layer_rebuild_steps == 1`, the old front still installed and
##                still returning exactly the same numbers. SAVE.
##   d1 finish    the continuous run folds the job it already had.
##   d2           economy day 2, then ideology day 2, on both sides.
func _run_time_point_6(batches: Array) -> Dictionary:
	print("[sv6] ---- time point 6: MATERIALIZE mid-shard, candidate not installed ----")
	var cont: Dictionary = _new_world("tp6-continuous", 2)
	var ext: Object = cont["ext"]
	var handle: int = int(cont["handle"])
	var owned: int = int(cont["owned"])
	var expect_cells: int = 2 * owned

	_submit(ext, batches[0], handle)   # grant points
	_submit(ext, batches[1], handle)   # discover
	_submit(ext, batches[2], handle)   # equip
	_run_one_ideology_day(ext, 0, "tp6/cont")
	# Plan 10.1 as implemented: the pending equip contributes NOTHING, so day 0's own
	# rebuild publishes no front yet.
	var pre_settle: Dictionary = ext.get_derived_cell_layer_report()
	_expect("tp6: while the equip transition is PENDING the card contributes "
		+ "NOTHING (no front installed, generation 0)",
		not bool(pre_settle.get("installed", true))
		and int(pre_settle.get("layer_generation", -1)) == 0
		and int(pre_settle.get("cell_count", -1)) == 0,
		"installed=%s generation=%s cells=%s" % [
			str(pre_settle.get("installed", "?")),
			str(pre_settle.get("layer_generation", "?")),
			str(pre_settle.get("cell_count", "?"))])
	# The equip's own transition is still pending after day 0, so day 0's rebuild
	# published an EMPTY front (plan 10.1: an un-ACKed equip contributes
	# nothing, `ideology_runtime.cpp:2317-2318`). Serve the adapters and re-enter
	# day 0 ONCE: that pass POLLS the ACK and SETTLES the transition, which records
	# confirmed_day 0 / eligible_from_day 1 -- and is then REFUSED by the §9.3 gate,
	# so it publishes nothing either. Day 1 is what gives this fixture the OLD front
	# that day 1's mid-materialize rebuild must keep serving.
	var served: Dictionary = _serve_native_adapters(ext, 0, "tp6")
	_expect("tp6: the native Effect adapters accepted and ACKED the equip's "
		+ "level commands",
		bool(served.get("ok", false)) and bool(served.get("effect_acked", false)),
		str(served))
	_run_one_ideology_day(ext, 0, "tp6/cont/settle")
	var settled0: Dictionary = ext.get_ideology_report()
	_expect("tp6: the equip's transition is SETTLED after the settle pass "
		+ "(pending_transitions == 0)",
		int(settled0.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(settled0.get("pending_transitions", "?")))
	# -- the state §9.3 creates: CONFIRMED on day 0, publishable on day 1 ---
	_expect("tp6: the equip's projection is CONFIRMED on day 0 and eligible only "
		+ "from day 1",
		int(settled0.get("derived_basis_confirmed_day", -1)) == 0
			and int(settled0.get("derived_basis_eligible_day", -1)) == 1,
		"confirmed=%s eligible=%s" % [
			str(settled0.get("derived_basis_confirmed_day", "?")),
			str(settled0.get("derived_basis_eligible_day", "?"))])
	_expect("tp6: day 0's rebuild was REFUSED by the eligibility gate "
		+ "(derived_rebuild_gated_by_eligibility > 0)",
		int(settled0.get("derived_rebuild_gated_by_eligibility", 0)) > 0,
		"gated=%s" % str(settled0.get(
			"derived_rebuild_gated_by_eligibility", "?")))
	var confirmed_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("tp6: the confirmation day publishes NOTHING (the previous front -- "
		+ "the empty one -- is still in force)",
		not bool(confirmed_layer.get("installed", true))
			and int(confirmed_layer.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [
			str(confirmed_layer.get("installed", "?")),
			str(confirmed_layer.get("cell_count", "?"))])
	print("[sv6] confirmed-not-eligible: confirmed_day=%s eligible_from_day=%s "
		% [str(settled0.get("derived_basis_confirmed_day", "?")),
			str(settled0.get("derived_basis_eligible_day", "?"))]
		+ "gated=%s front installed=%s cells=%s sample_day=%s"
		% [str(settled0.get("derived_rebuild_gated_by_eligibility", "?")),
			str(confirmed_layer.get("installed", "?")),
			str(confirmed_layer.get("cell_count", "?")),
			str(confirmed_layer.get("sample_day", "?"))])
	# -- the eligibility day installs the OLD front ------------------------
	_run_one_ideology_day(ext, 1, "tp6/cont/eligible")
	var drained0: Dictionary = ext.drain_derived_cell_layer(1)
	_expect("tp6: the eligibility day's rebuild folds to completion (a front "
		+ "exists before the save)", bool(drained0.get("complete", false)),
		str(drained0))
	var layer_before: Dictionary = ext.get_derived_cell_layer_report()
	var gen_before := int(layer_before.get("layer_generation", -1))
	var cells_before := int(layer_before.get("cell_count", -1))
	_expect("tp6: the OLD front is installed and serving before day 1's rebuild",
		bool(layer_before.get("installed", false)) and cells_before == expect_cells
			and int(layer_before.get("sample_day", -1)) == 1,
		"installed=%s cells=%s sample_day=%s (expected %d)" % [
			str(layer_before.get("installed", "?")), str(cells_before),
			str(layer_before.get("sample_day", "?")), expect_cells])
	# The numbers the old front returns, so "still serving" is proven by equality
	# rather than by the report flag alone.
	var probe_before: Dictionary = _probe_all_cells(ext, STAT_ADD)

	# -- pump day 1 again, one slice at a time, and stop mid-materialize --
	# This is a second pass over day 1, which is legal (`_last_day < day` is false,
	# so nothing accrues twice) and is the only way to observe the collect slice of
	# a day whose front is already installed.
	var pump: Dictionary = _pump_to_mid_materialize(ext, 1)
	for line in pump["trace"]:
		print("[sv6] %s" % String(line))
	_expect("tp6: the rebuild is genuinely IN FLIGHT at save time "
		+ "(derived_rebuild_pending == true)",
		bool(pump.get("found", false)),
		"no slice reported stage=ideology_derived_rebuild with steps==1; "
		+ "last=%s" % str(pump.get("last", {})))
	if not bool(pump.get("found", false)):
		return {"final": {}, "save_bytes": PackedByteArray()}
	var mid_report: Dictionary = ext.get_ideology_report()
	var mid_slice: Dictionary = pump["slice"]
	_expect("tp6: the in-flight slice is the collect step of this day "
		+ "(stage=ideology_derived_rebuild, done=false, steps==1)",
		String(mid_slice.get("stage", "")) == "ideology_derived_rebuild"
		and not bool(mid_slice.get("done", true))
		and int(mid_report.get("cell_layer_rebuild_steps", -1)) == 1,
		"stage=%s done=%s steps=%s" % [str(mid_slice.get("stage", "?")),
			str(mid_slice.get("done", "?")),
			str(mid_report.get("cell_layer_rebuild_steps", "?"))])
	_expect("tp6: work has really been done, not merely scheduled "
		+ "(rebuild_steps >= 1 AND rebuild_visits > 0)",
		int(mid_report.get("cell_layer_rebuild_steps", 0)) >= 1
		and int(mid_report.get("cell_layer_rebuild_visits", 0)) > 0,
		"steps=%s visits=%s" % [
			str(mid_report.get("cell_layer_rebuild_steps", "?")),
			str(mid_report.get("cell_layer_rebuild_visits", "?"))])

	var mid_layer: Dictionary = ext.get_derived_cell_layer_report()
	var mid_probe: Dictionary = _probe_all_cells(ext, STAT_ADD)
	_expect("tp6: the candidate is NOT installed: the layer generation is unchanged",
		int(mid_layer.get("layer_generation", -1)) == gen_before,
		"%d -> %s" % [gen_before, str(mid_layer.get("layer_generation", "?"))])
	_expect("tp6: the OLD front is still serving while the candidate is built "
		+ "(installed, same cell count)",
		bool(mid_layer.get("installed", false))
		and int(mid_layer.get("cell_count", -1)) == cells_before,
		"installed=%s cells=%s" % [str(mid_layer.get("installed", "?")),
			str(mid_layer.get("cell_count", "?"))])
	_expect("tp6: the old front still returns EXACTLY the same numbers mid-rebuild "
		+ "(presence/add/value, %s)" % STAT_ADD,
		_presence_diff(probe_before["present"], mid_probe["present"])
			.begins_with("mismatches=0")
		and _float_diff(probe_before["add"], mid_probe["add"])
			.begins_with("mismatches=0")
		and _float_diff(probe_before["value"], mid_probe["value"])
			.begins_with("mismatches=0"),
		"%s | %s" % [_presence_diff(probe_before["present"], mid_probe["present"]),
			_float_diff(probe_before["add"], mid_probe["add"])])

	# -- the safe boundary, MEASURED -------------------------------------
	var boundary_allows: bool = not bool(ext.ideology_should_run(1))
	print("[sv6] boundary: ideology_should_run(1)=%s -> production gate would %s"
		% [str(not boundary_allows), "ALLOW" if boundary_allows else "REFUSE"])
	_expect("tp6: the production save boundary reports idle at the mid-materialize "
		+ "instant (ideology_should_run == false), so the capture is inside the "
		+ "existing safe boundary",
		boundary_allows,
		"ideology_should_run=%s (should_run has no derived_rebuild_pending term: "
			% str(not boundary_allows)
		+ "ideology_runtime.cpp:5057-5068; gate at game_save_coordinator.gd:416-421)")

	# -- capture AT that instant -----------------------------------------
	var mid_state: Dictionary = _capture_state(cont, "tp6-cont/mid", true, 1,
		PROGRAM_L1)
	var saved: Dictionary = _capture_pair(ext, "tp6/SAVE")
	var mid_bytes: PackedByteArray = saved.get("pkid", PackedByteArray())
	var capture_permitted := not mid_bytes.is_empty()
	_expect("tp6: PKID capture IS PERMITTED mid-materialize "
		+ "(the shipped capture() has no pending-rebuild guard)",
		capture_permitted and _ascii_magic(mid_bytes) == "PKID"
		and bool(mid_state["layer"].get("installed", false)),
		"bytes=%d magic=%s (capture() at ideology_runtime.cpp:6393-6499 writes "
			% [mid_bytes.size(), _ascii_magic(mid_bytes)]
		+ "countries/ideas/commands only -- no job, no candidate, no front)")
	if not capture_permitted:
		print("[sv6] FINDING: the mid-materialize capture was REFUSED "
			+ "(empty PKID payload) -- that is the finding for plan line 806")
		return {"final": {}, "save_bytes": mid_bytes}
	print("[sv6] FINDING: mid-materialize capture permitted, %d bytes "
		% mid_bytes.size()
		+ "(pkef=%d), pending=%s steps=%s"
		% [(saved.get("pkef", PackedByteArray()) as PackedByteArray).size(),
			str(mid_report.get("derived_rebuild_pending", "?")),
			str(mid_report.get("cell_layer_rebuild_steps", "?"))])

	# -- finish day 1 in the continuous run ------------------------------
	var finish_slices := 0
	var finish_last: Dictionary = {}
	for _i in range(512):
		finish_last = ext.run_ideology_daily(1)
		finish_slices += 1
		if not bool(finish_last.get("ok", true)):
			_expect("tp6: the continuous run's fold step reports ok", false,
				str(finish_last))
			break
		if bool(finish_last.get("done", false)):
			break
	_expect("tp6: the continuous run's in-flight job folds to completion",
		bool(finish_last.get("done", false)) and finish_slices >= 1,
		"slices=%d stage=%s" % [finish_slices,
			str(finish_last.get("stage", "?"))])
	var after_fold: Dictionary = ext.get_derived_cell_layer_report()
	var drained1: Dictionary = ext.drain_derived_cell_layer(1)
	_expect("tp6: no rebuild is left pending after the fold",
		bool(drained1.get("complete", false))
		and not bool(ext.get_ideology_report().get("derived_rebuild_pending", true)),
		str(drained1))
	print("[sv6] after fold: installed=%s cells=%s generation=%s"
		% [str(after_fold.get("installed", "?")),
			str(after_fold.get("cell_count", "?")),
			str(after_fold.get("layer_generation", "?"))])

	_advance_economy_day(ext, 2, "tp6/cont")
	_run_one_ideology_day(ext, 2, "tp6/cont")
	var cont_final: Dictionary = _capture_state(cont, "tp6-cont/final", true, 2,
		PROGRAM_L1)

	# -- reload of the mid-materialize save ------------------------------
	var reload: Dictionary = _new_world("tp6-reload", 2)
	var rext: Object = reload["ext"]
	var r_ok: Dictionary = _restore_pair(rext, saved, "tp6")
	_expect("tp6: the mid-materialize PKEF+PKID pair IS ACCEPTED by restore "
		+ "(the state hash does not cover the in-flight job)",
		bool(r_ok.get("ok", false)), str(r_ok.get("reason", r_ok)))
	var r_layer_at_restore: Dictionary = rext.get_derived_cell_layer_report()
	_expect("tp6: NO partial front leaks out of the save "
		+ "(the reloaded runtime starts with no layer at all)",
		not bool(r_layer_at_restore.get("installed", true))
		and int(r_layer_at_restore.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [str(r_layer_at_restore.get("installed", "?")),
			str(r_layer_at_restore.get("cell_count", "?"))])
	var r_business: Dictionary = rext.get_ideology_business_state()
	_expect("tp6: the restored business state is byte-identical to the mid-flight one",
		int(r_business.get("hash", 0)) == int(mid_state["business"].get("hash", -1)),
		"%s vs %s" % [str(r_business.get("hash", "?")),
			str(mid_state["business"].get("hash", "?"))])
	_expect("tp6: the restored runtime has no command left pending",
		int(rext.get_ideology_report().get("pending_commands", -1)) == 0,
		str(rext.get_ideology_report().get("pending_commands", "?")))

	_run_one_ideology_day(rext, 1, "tp6/reload")
	var r_drained1: Dictionary = rext.drain_derived_cell_layer(1)
	var r_layer1: Dictionary = rext.get_derived_cell_layer_report()
	_expect("tp6: the reloaded runtime rebuilds the interrupted day from scratch",
		bool(r_drained1.get("complete", false))
		and int(r_layer1.get("layer_generation", 0)) >= 1
		and int(r_layer1.get("cell_count", -1)) == expect_cells,
		"drained=%s generation=%s cells=%s" % [str(r_drained1),
			str(r_layer1.get("layer_generation", "?")),
			str(r_layer1.get("cell_count", "?"))])
	_advance_economy_day(rext, 2, "tp6/reload")
	_run_one_ideology_day(rext, 2, "tp6/reload")
	var r_final: Dictionary = _capture_state(reload, "tp6-reload/final", true, 2,
		PROGRAM_L1)

	_compare(cont_final, r_final, "tp6/final", 0)
	# The number of INSTALLS is part of the evidence: the continuous run installed
	# once (day 0) and every later rebuild was content-identical and skipped (I13);
	# the reload installed once (during the interrupted day's re-run). Equal counts,
	# different install DAYS -- which is what "the front is a pure derivation and is
	# not saved" means.
	var cont_gen := int(cont_final["layer_generation"])
	var r_gen := int(r_final["layer_generation"])
	_expect("tp6: both runs performed the same number of installs "
		+ "(the reload rebuilt what the save did not carry)",
		cont_gen == r_gen and cont_gen >= 1,
		"continuous=%d reload=%d" % [cont_gen, r_gen])
	print("[sv6] install days: continuous sample_day=%s reload sample_day=%s "
		% [str(cont_final["layer"]["sample_day"]),
			str(r_final["layer"]["sample_day"])]
		+ "(they differ by design: the save carries no front, so the reload's install "
		+ "is the rebuild of the interrupted day)")

	return {"final": cont_final, "save_bytes": mid_bytes,
		"mid_slices": finish_slices}


## Pumps `run_ideology_daily(day)` ONE SLICE at a time until the runtime is in the
## "collect done, candidate built, nothing installed" state.
##
## The stop test is `stage == ideology_derived_rebuild`, `done == false` and
## `cell_layer_rebuild_steps == 1`:
##   * `steps == 1` is the collect step (`ideology_runtime.cpp:7033`) and the only
##     instant at which the job exists while the front does not change;
##   * the counter is NOT reset on a day change (`:6991-7004` resets the slice
##     counter but leaves `_derived_rebuild_steps`), so requiring exactly 1 also
##     rejects a stale value from the previous day.
func _pump_to_mid_materialize(ext: Object, day: int) -> Dictionary:
	var trace := PackedStringArray()
	for i in range(512):
		var slice: Dictionary = ext.run_ideology_daily(day)
		var report: Dictionary = ext.get_ideology_report()
		var layer: Dictionary = ext.get_derived_cell_layer_report()
		var stage := String(slice.get("stage", ""))
		var steps := int(report.get("cell_layer_rebuild_steps", -1))
		var pending := bool(report.get("derived_rebuild_pending", false))
		trace.append("slice=%d done=%s stage=%s steps=%d pending=%s gen=%s cells=%s"
			% [i, str(slice.get("done", "?")), stage, steps, str(pending),
				str(layer.get("layer_generation", "?")),
				str(layer.get("cell_count", "?"))])
		if not bool(slice.get("ok", true)):
			return {"found": false, "trace": trace, "last": slice}
		if stage == "ideology_derived_rebuild" and not bool(slice.get("done", true)) \
				and pending and steps == 1:
			return {"found": true, "trace": trace, "slice": slice}
		if bool(slice.get("done", false)):
			return {"found": false, "trace": trace, "last": slice}
	return {"found": false, "trace": trace, "last": {}}


## Point-6 batches: the plain equip lead. Sequences are fixed and every branch
## submits the same rows.
func _tp6_batches(dense: int) -> Array:
	return [
		_batch(OP_GRANT, 0, -1, 64 * Q16_ONE, 1),
		_batch(OP_DISCOVER, 0, dense, 0, 2),
		_batch(OP_EQUIP, 0, dense, 0, 3),
	]


# =========================================================================
# production side channels: the native Effect adapters, and the PKEF/PKID pair
# =========================================================================

## Serves the native Effect adapters, which is what the daily graph does every day
## (`dispatch_effect_native_modifier` / `ack_effect_native_modifier` are bound at
## `world_ext_bind_methods.cpp:635-638`). Without this the equip's level transaction
## stays at PENDING forever, `pending_transition_count` never returns to 0, and no
## later idea command can land (`equip`/`unequip` refuse, and
## `start_next_level_transition` returns early).
func _serve_native_adapters(ext: Object, day: int, label: String) -> Dictionary:
	var rounds := 0
	var ok := true
	var effect_acked := false
	for _i in range(8):
		rounds += 1
		ext.run_effect_daily(day)
		var d_mod: Dictionary = ext.dispatch_effect_native_modifier()
		# The dispatch SUBMITS the rows to the Modifier runtime; they complete when
		# that domain runs its own day (`run_modifier_daily`, bound at
		# `world_ext_bind_methods.cpp:471`). Without this the ack below keeps
		# reporting `pending` and the ideology transition never settles.
		ext.run_modifier_daily(day)
		var a_mod: Dictionary = ext.ack_effect_native_modifier()
		var d_cty: Dictionary = ext.dispatch_effect_native_country()
		var a_cty: Dictionary = ext.ack_effect_native_country()
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
		var report: Dictionary = ext.get_ideology_report()
		if int(a_mod.get("acknowledged", 0)) > 0 \
				and int(a_mod.get("pending", 0)) == 0:
			# The EFFECT side has acked the transaction. The ideology runtime has
			# not polled it yet: `_pending_transitions` is only drained at the start
			# of a `run_ideology_daily` slice (`ideology_runtime.cpp:4918-4932`), so
			# the next ideology day is what turns this into a settled transition.
			effect_acked = true
			break
		if int(report.get("pending_transitions", -1)) == 0:
			effect_acked = true
			break
	var final_report: Dictionary = ext.get_ideology_report()
	var adapters: Dictionary = ext.get_effect_native_adapter_report()
	# `pending_transitions` here is the PRE-POLL value: the Effect domain has acked,
	# the ideology runtime has not polled yet. The next ideology day settles it, and
	# that is what the callers assert on.
	print("[%s/adapters] rounds=%d effect_acked=%s pre_poll_pending_transitions=%s "
		% [label, rounds, str(effect_acked),
			str(final_report.get("pending_transitions", "?"))]
		+ "queues=%s"
		% [str({"country": adapters.get("country_pending", "?"),
			"economy": adapters.get("economy_pending", "?"),
			"gameplay": adapters.get("gameplay_pending", "?")})])
	return {"ok": ok, "rounds": rounds, "effect_acked": effect_acked,
		"pre_poll_pending_transitions": int(
			final_report.get("pending_transitions", -1)),
		"adapters": adapters}


## The production SECTION PAIR and its order: PKEF first, then PKID
## (`scripts/game/game_save_coordinator.gd:10,967,1154`; the ordering is required by
## `ideology_runtime.cpp:6748-6751,6793-6812`).
func _capture_pair(ext: Object, label: String) -> Dictionary:
	var pkef: PackedByteArray = ext.capture_effect_state()
	var pkid: PackedByteArray = ext.capture_ideology_state()
	_expect("%s: PKEF payload is produced" % label, not pkef.is_empty(),
		str(pkef.size()))
	_expect("%s: PKID payload is produced and carries the PKID magic" % label,
		_ascii_magic(pkid) == "PKID", "%s (%d bytes)" % [_ascii_magic(pkid),
			pkid.size()])
	return {"pkef": pkef, "pkid": pkid}


func _restore_pair(ext: Object, pair: Dictionary, label: String) -> Dictionary:
	var pkef: PackedByteArray = pair.get("pkef", PackedByteArray())
	var pkid: PackedByteArray = pair.get("pkid", PackedByteArray())
	var effect_result: Dictionary = ext.restore_effect_state(pkef)
	_expect("%s: PKEF restores FIRST (the order PKID's binding check requires)"
		% label, bool(effect_result.get("ok", false)),
		str(effect_result.get("reason", effect_result)))
	var result: Dictionary = ext.restore_ideology_state(pkid)
	if not bool(result.get("ok", false)):
		# The reason code is the whole diagnosis: truncation, catalog mismatch,
		# state-hash mismatch and binding mismatch all report `ok=false`.
		print("[%s/restore] reason=%s" % [label, String(result.get("reason", ""))])
	return result


# =========================================================================
# negative control
# =========================================================================

## Proves the comparison CAN fail.
##
## Every helper used below is also used to PASS points 5 and 6, so "the two runs
## match" would be unfalsifiable if the helpers could not report a difference. Each
## one is handed a deliberately damaged snapshot and must report exactly the damage
## that was introduced.
func _negative_control(tp5: Dictionary, tp6: Dictionary) -> void:
	print("[negctl] ---- negative control: the comparisons must be able to fail ----")
	var reference: Dictionary = tp5.get("final", {})
	if reference.is_empty():
		_expect("negctl: a point-5 reference state exists to damage", false, "")
		return
	# Damage: one presence byte flipped, one add moved by 1e-9 (the smallest
	# difference the EXACT comparison is supposed to see), one value moved by 0.25.
	var damaged: Dictionary = reference.duplicate(true)
	var row: Dictionary = damaged["cells"][STAT_ADD]
	var present: PackedByteArray = row["present"]
	var add: PackedFloat64Array = row["add"]
	var value: PackedFloat64Array = row["value"]
	var presence_cell := -1
	for c in range(CELLS):
		if present[c] != 0:
			presence_cell = c
			present[c] = 0
			break
	if presence_cell < 0:
		for c in range(CELLS):
			if present[c] == 0:
				presence_cell = c
				present[c] = 1
				break
	add[3] = add[3] + 0.000000001
	value[5] = value[5] + 0.25
	row["present"] = present
	row["add"] = add
	row["value"] = value
	damaged["cells"][STAT_ADD] = row

	var p := _presence_diff(reference["cells"][STAT_ADD]["present"], present)
	var f := _float_diff(reference["cells"][STAT_ADD]["add"], add)
	var v := _float_diff(reference["cells"][STAT_ADD]["value"], value)
	_expect("negctl: the per-cell PRESENCE comparison reports the flipped cell "
		+ "(negative control)", _mismatches(p) >= 1, p)
	_expect("negctl: the per-cell ADD comparison reports a 1e-9 difference "
		+ "(negative control)", _mismatches(f) >= 1, f)
	_expect("negctl: the per-cell VALUE comparison reports the moved cell "
		+ "(negative control)", _mismatches(v) >= 1, v)
	_expect("negctl: the per-cell fingerprint changes when one cell changes "
		+ "(negative control)",
		String(_fingerprint(damaged["cells"])) != String(reference["fingerprint"]),
		"%s vs %s" % [String(_fingerprint(damaged["cells"])),
			String(reference["fingerprint"])])
	print("[negctl] mismatch counts: presence=%d add=%d value=%d"
		% [_mismatches(p), _mismatches(f), _mismatches(v)])

	# Business state: the same equality test the time points rely on must be able
	# to say "different".
	var reference_business: Dictionary = reference["business"]
	var damaged_business: Dictionary = damaged["business"].duplicate()
	var reference_hash := int(reference_business.get("hash", 0))
	damaged_business["hash"] = reference_hash ^ 1
	_expect("negctl: the business-hash comparison reports a one-bit change "
		+ "(negative control)",
		not (reference_hash == int(damaged_business.get("hash", 0))),
		"%d vs %d" % [reference_hash, int(damaged_business.get("hash", -1))])

	# A PKID payload with a flipped byte must be REFUSED by restore. This is the
	# other half of the negative control: it proves the save is validated, so
	# "restore ok" in the two time points means something.
	var save_bytes: PackedByteArray = tp5.get("save_bytes", PackedByteArray())
	if save_bytes.size() >= 8:
		var corrupt: PackedByteArray = save_bytes.duplicate()
		var at: int = corrupt.size() / 2
		corrupt[at] = corrupt[at] ^ 0xFF
		var scratch: Dictionary = _new_world("negctl-scratch", 1)
		var result: Dictionary = scratch["ext"].restore_ideology_state(corrupt)
		_expect("negctl: a PKID payload with one flipped byte is REFUSED "
			+ "(negative control)",
			not bool(result.get("ok", true)) and String(result.get("reason", "")) != "",
			"ok=%s reason=%s byte=%d" % [str(result.get("ok", "?")),
				str(result.get("reason", "?")), at])
		print("[negctl] corrupted payload -> ok=%s reason=%s"
			% [str(result.get("ok", "?")), str(result.get("reason", "?"))])
	else:
		_expect("negctl: a point-5 PKID payload exists to corrupt", false, "")


# =========================================================================
# plan 18.2: the applied-program basis, against the catalogs
# =========================================================================

## Proves the plan 18.2 basis block is REAL DATA about the projection, and that a reload
## refuses when it cannot be rebuilt from the current catalogs.
##
## The robustness fixture covers the block's SHAPE (a lying length/count, and the EMPTY
## block a world with a pending equip correctly persists). This one covers its CONTENT,
## which needs a SETTLED card: this harness serves the native Effect adapters, so the
## equip reaches ACKED and the card contributes at level 0 by the time the day-3 save is
## taken.
func _applied_basis_control(tp5: Dictionary) -> void:
	print("[basis] ---- plan 18.2: the applied-program basis ----")
	var payload: PackedByteArray = tp5.get("save_bytes", PackedByteArray())
	if payload.size() <= 64:
		_expect("basis: the day-3 PKID payload exists to inspect", false,
			"%d bytes" % payload.size())
		return
	var tail: Dictionary = _pkid_tail(payload)
	var walk: Dictionary = _walk_basis_block(payload, int(tail["basis_block_off"]))
	_expect("basis: the block parses and its length field is honest",
		String(walk["error"]).is_empty()
			and int(walk["end"]) == int(tail["basis_len_off"]),
		"error=%s end=%d expected=%d" % [String(walk["error"]),
			int(walk["end"]), int(tail["basis_len_off"])])
	_expect("basis: a SETTLED level-0 card persists exactly ONE (country, program) row "
		+ "-- the card's cost row (target_domain 1) must NOT be in the basis",
		int(walk["rows"]) == 1, str(walk["rows"]))
	_expect("basis: the row names the level-0 program (%s, got %s)"
		% [PROGRAM_L1, String(walk["first_program_key"])],
		String(walk["first_program_key"]) == PROGRAM_L1,
		String(walk["first_program_key"]))
	_expect("basis: the row carries selector kind 12 (SELECTOR_OWN_TERRITORY)",
		int(walk["first_selector_kind"]) == 12,
		str(walk["first_selector_kind"]))
	_expect("basis: the row carries a non-zero terms digest",
		int(walk["first_terms_digest"]) != 0, str(walk["first_terms_digest"]))
	print("[basis] rows=%d program=%s kind=%d digest=%d block=%d bytes"
		% [int(walk["rows"]), String(walk["first_program_key"]),
			int(walk["first_selector_kind"]), int(walk["first_terms_digest"]),
			int(tail["basis_block_bytes"])])
	if int(walk["first_digest_off"]) <= 0:
		_expect("basis: the payload exposes the first row's digest offset", false, "")
		return
	# (1) A row the catalogs cannot reproduce. The digest is the one field a reload cannot
	# derive from anything else in the payload, so flipping it is exactly "written under
	# different fold inputs". Note WHICH layer answers: the basis comparison runs BEFORE
	# the state hash (which also covers the block), so this must NOT come back as
	# `ideology_save_state_hash_mismatch`.
	var scratch: Object = _build_basis_runtime(_catalogs["native_ideology"])
	var damaged: PackedByteArray = payload.duplicate()
	var digest_off: int = int(walk["first_digest_off"])
	damaged.encode_u8(digest_off, damaged.decode_u8(digest_off) ^ 0x01)
	var damaged_result: Dictionary = scratch.restore_ideology_state(damaged)
	_expect("basis: a digest the catalogs cannot rebuild is refused BY NAME (not as a "
		+ "state-hash mismatch)",
		String(damaged_result.get("reason", ""))
			== "ideology_save_applied_basis_mismatch",
		"ok=%s reason=%s" % [str(damaged_result.get("ok", "?")),
			String(damaged_result.get("reason", ""))])
	print("[basis] damaged digest -> ok=%s reason=%s (offset %d)"
		% [str(damaged_result.get("ok", "?")),
			String(damaged_result.get("reason", "")), digest_off])
	# (2) THE HOLE THIS BLOCK CLOSES, measured. The card-level -> program mapping is NOT
	# covered by `compute_catalog_hash` (it hashes level thresholds and daily
	# understanding, never `Level::persistent_*` / `EffectTemplate::definition_key`) and
	# not by the execution contract (which covers the OTHER two catalogs). So a build
	# that assigns a different program to the same card level agrees with this one on
	# every other persisted identity -- and before v13 the reload silently re-projected
	# the other program.
	var remapped: Dictionary = _remap_program_catalog(
		String(PROGRAM_L1).replace("ideology.effect.", ""),
		String(PROGRAM_L2).replace("ideology.effect.", ""))
	if int(remapped.get("moved", 0)) != 1:
		_expect("basis cross-build: the alternate catalog moved one program assignment",
			false, str(remapped))
		return
	var mapped: Object = _build_basis_runtime(remapped["catalog"])
	var mapped_catalog := int(mapped.get_ideology_business_state().get(
		"catalog_hash", 0))
	var scratch_catalog := int(scratch.get_ideology_business_state().get(
		"catalog_hash", 0))
	var mapped_contract := int(mapped.get_ideology_report().get(
		"execution_contract_hash", 0))
	var scratch_contract := int(scratch.get_ideology_report().get(
		"execution_contract_hash", 0))
	_expect("basis cross-build: both builds agree on the ideology CATALOG hash (%d) "
		% mapped_catalog + "even though their card->program mappings differ",
		mapped_catalog != 0 and mapped_catalog == scratch_catalog,
		"mapped=%d plain=%d" % [mapped_catalog, scratch_catalog])
	_expect("basis cross-build: ... and on the execution CONTRACT hash (%d)"
		% mapped_contract,
		mapped_contract != 0 and mapped_contract == scratch_contract,
		"mapped=%d plain=%d" % [mapped_contract, scratch_contract])
	# Symmetry: the remapped build CAN reload its own capture, so the refusal below is
	# data rather than a runtime that cannot restore anything.
	var mapped_own: Dictionary = mapped.restore_ideology_state(
		mapped.capture_ideology_state())
	_expect("basis cross-build: the remapped build reloads its OWN capture",
		bool(mapped_own.get("ok", false)),
		"ok=%s reason=%s" % [str(mapped_own.get("ok", "?")),
			String(mapped_own.get("reason", ""))])
	var mapped_result: Dictionary = mapped.restore_ideology_state(payload)
	_expect("basis cross-build: the remapped build REFUSES the source's payload by "
		+ "name instead of re-projecting a different program",
		String(mapped_result.get("reason", ""))
			== "ideology_save_applied_basis_mismatch",
		"ok=%s reason=%s" % [str(mapped_result.get("ok", "?")),
			String(mapped_result.get("reason", ""))])
	print("[basis/remap] restore -> ok=%s reason=%s (catalog=%d==%d "
		% [str(mapped_result.get("ok", "?")),
			String(mapped_result.get("reason", "")), mapped_catalog,
			scratch_catalog]
		+ "contract=%d==%d)" % [mapped_contract, scratch_contract])

	# ── ATOMICITY: a refusal AFTER the basis is parsed must not half-write it ──
	#
	# This is the exact bug class that bit the two basis dates: `restore` assigns them at
	# a commit point and `rollback` puts the previous values back. The basis was added to
	# that same list of assignments, and this asserts it is in the `rollback` half too.
	#
	# The damage is applied to a field the reader checks LAST (the state hash), so the
	# payload's basis is parsed, shape-validated and ACCEPTED by the rebuild comparison
	# before the refusal -- which is precisely the window in which a partial assignment
	# would survive. The payload is from the day-3 (level 0) window while the live world
	# has since levelled up, so its basis names a DIFFERENT program: a half-write would
	# be visible, not indistinguishable from no-op.
	var live: Variant = tp5.get("ext", null)
	if live == null:
		_expect("basis atomicity: the point-5 world object is available", false, "")
		return
	var live_ext: Object = live
	var before_report: Dictionary = live_ext.get_ideology_report()
	var rows_before := int(before_report.get("applied_program_basis_rows", -1))
	var digest_before := int(before_report.get("applied_program_basis_digest", 0))
	var program_before := String(before_report.get(
		"applied_program_basis_first_program", ""))
	var payload_program := String(walk["first_program_key"])
	_expect("basis atomicity: the live world holds an applied basis to protect "
		+ "(rows=%d, %s)" % [rows_before, program_before], rows_before >= 1,
		"rows=%d" % rows_before)
	_expect("basis atomicity: the payload's row names a DIFFERENT program than the "
		+ "runtime holds now (%s vs %s)" % [payload_program, program_before],
		payload_program != "" and payload_program != program_before,
		"payload=%s runtime=%s" % [payload_program, program_before])
	var state_hash_off := 32   # PKID header: magic 4, schema 4, catalog 8, day 8, order 8
	var bad_state_hash: PackedByteArray = payload.duplicate()
	bad_state_hash.encode_u64(state_hash_off,
		bad_state_hash.decode_u64(state_hash_off) ^ 1)
	var atomic_result: Dictionary = live_ext.restore_ideology_state(bad_state_hash)
	_expect("basis atomicity: the damaged state hash is refused by name, so the "
		+ "refusal really happened AFTER the basis was accepted",
		String(atomic_result.get("reason", ""))
			== "ideology_save_state_hash_mismatch",
		"ok=%s reason=%s" % [str(atomic_result.get("ok", "?")),
			String(atomic_result.get("reason", ""))])
	var after_report: Dictionary = live_ext.get_ideology_report()
	_expect("basis atomicity: the applied basis is UNCHANGED by that refusal "
		+ "(rollback, not half-write)",
		int(after_report.get("applied_program_basis_rows", -2)) == rows_before
			and int(after_report.get("applied_program_basis_digest", 0))
				== digest_before
			and String(after_report.get("applied_program_basis_first_program", ""))
				== program_before,
		"rows %d->%d digest %d->%d program %s->%s" % [
			rows_before,
			int(after_report.get("applied_program_basis_rows", -2)),
			digest_before,
			int(after_report.get("applied_program_basis_digest", 0)),
			program_before,
			String(after_report.get(
				"applied_program_basis_first_program", ""))])
	print("[basis/atomic] rows=%d program=%s digest=%d preserved across a refusal "
		% [rows_before, program_before, digest_before]
		+ "(payload would have installed %s)" % payload_program)


# =========================================================================
# plan 18.5 -- the LOCAL SCALAR BASIS and the sample-day identity
# =========================================================================
##
## The applied basis above pins WHICH programs the projection folds. This one pins the
## NUMBERS their programs read: the ideology-local scalar values published into the
## Effect metric slab (`fill_ideology_scalars`), one row per (country, slab metric id),
## plus the sample day the projection was built for.
##
## Why the CONTENT check lives here rather than in the robustness fixture: it needs a
## world whose Effect catalog resolves the `ideology.scalar.*` keys AND whose Country
## domain answers `unlocked_era_for`, so that the rebuild reproduces every row. A
## catalog-only scratch runtime reproduces all but the era row, which would make the
## refusal fire for the wrong reason.
func _scalar_basis_control(tp5: Dictionary) -> void:
	print("[basis] ---- plan 18.5: the local scalar basis + sample day ----")
	var payload: PackedByteArray = tp5.get("save_bytes", PackedByteArray())
	var live: Variant = tp5.get("ext", null)
	if payload.size() <= 64 or live == null:
		_expect("scalar basis: the day-3 PKID payload and its world are available",
			false, "%d bytes ext=%s" % [payload.size(), str(live != null)])
		return
	var live_ext: Object = live
	var tail: Dictionary = _pkid_tail(payload)
	var block_off := int(tail["scalar_block_off"])
	var scalar_bytes := int(tail["scalar_block_bytes"])
	var scalar_end := int(tail["scalar_rows_end"])
	_expect("scalar basis: the block's declared length covers count + rows (declared "
		+ "%d, walked %d)" % [scalar_bytes, scalar_end - block_off],
		block_off > 0 and scalar_bytes >= 4
			and scalar_end == block_off + scalar_bytes
			and scalar_end == int(tail["scalar_len_off"]),
		str(tail))
	var walk: Dictionary = _walk_scalar_block(payload, block_off)
	print("[basis/scalars] rows=%d block=%d bytes first_metric=%d first_value=%d "
		% [int(walk["rows"]), scalar_bytes, int(walk["first_metric"]),
			int(walk["first_value"])]
		+ "nonzero=%d foreign_handles=%d ascending=%s error='%s'"
		% [int(walk["nonzero"]), int(walk["foreign_handles"]),
			str(walk["ascending"]), String(walk["error"])])
	_expect("scalar basis: the row count is real (%d rows) and every row names the "
		% int(walk["rows"]) + "payload's own country handle",
		String(walk["error"]).is_empty() and int(walk["rows"]) >= 1
			and int(walk["foreign_handles"]) == 0,
		"rows=%d foreign=%d error=%s" % [int(walk["rows"]),
			int(walk["foreign_handles"]), String(walk["error"])])
	_expect("scalar basis: metric ids strictly ascend (the reader's own shape rule, "
		+ "checked here as a property of the writer)", bool(walk["ascending"]),
		str(walk["ascending"]))
	# The card really is EQUIPPED in this world (level 0 settled), so `equipped_count`
	# is 1 and the block must carry a non-zero value. A block of zeros would mean the
	# values were derived from nothing.
	_expect("scalar basis: the equipped card shows up as a non-zero scalar value "
		+ "(nonzero rows=%d)" % int(walk["nonzero"]), int(walk["nonzero"]) >= 1,
		str(walk["nonzero"]))
	# ---- the SAMPLE DAY: the projection's own identity ---------------------
	#
	# `_derived_basis_sample_day` is read back from the INSTALLED front at every
	# install, so at the save boundary it must agree with both the front that was
	# serving readers then and the runtime's own member. The world has since rebuilt
	# the front for day 5, which is why "now" is measured too and printed: it proves
	# the number MOVED with the projection instead of being a constant.
	var report: Dictionary = live_ext.get_ideology_report()
	var at_save_report: Dictionary = tp5.get("at_save_report", {})
	var at_save_day := int(tp5.get("at_save_layer_day", -2))
	var save_report_day := int(at_save_report.get("derived_basis_sample_day", -3))
	var payload_day := int(tail["sample_day"])
	var now_day := int(report.get("derived_basis_sample_day", -4))
	print("[basis/sample-day] payload=%d report@save=%d front@save=%d now=%d "
		% [payload_day, save_report_day, at_save_day, now_day]
		+ "epoch_id=%d" % int(report.get("derived_basis_epoch_id", -1)))
	_expect("sample day: the payload carries the sample day the SAVE's projection was "
		+ "built for, matching the front that was serving then and the runtime's own "
		+ "report at that moment",
		payload_day == save_report_day and save_report_day == at_save_day
			and payload_day >= 0,
		"payload=%d report@save=%d front@save=%d" % [payload_day, save_report_day,
			at_save_day])
	_expect("sample day: the identity MOVED with the projection -- it now equals the "
		+ "front the world is serving (day %d) and no longer the save's day"
		% int(tp5.get("final", {}).get("layer", {}).get("sample_day", -5)),
		now_day == int(tp5.get("final", {}).get("layer", {}).get("sample_day", -5))
			and now_day != payload_day,
		"payload=%d now=%d front_now=%s" % [payload_day, now_day,
			str(tp5.get("final", {}).get("layer", {}).get("sample_day", "?"))])
	# Plan 18.5 deliberately persists the SAMPLE DAY only: `_derived_epoch_id` is
	# structurally 0 (declared once, never assigned, read only as the materializer's
	# argument), so a persisted epoch field would be 0 in every payload and would
	# validate nothing. This asserts the claim instead of trusting the comment.
	_expect("sample day: the front's epoch id is STRUCTURALLY 0, which is why the "
		+ "payload does not persist an epoch field",
		int(report.get("derived_basis_epoch_id", -1)) == 0,
		str(report.get("derived_basis_epoch_id", "?")))
	# ---- the CONTENT refusal, and the members' atomicity -------------------
	var rows_before := int(report.get("local_scalar_basis_rows", -1))
	var value_before := int(report.get("local_scalar_basis_first_value", 0))
	var day_before := int(report.get("derived_basis_sample_day", -2))
	var capture_before: PackedByteArray = live_ext.capture_ideology_state()
	# (1) A VALUE the catalogs cannot rebuild. The block is parsed, shape-checked and
	# then compared against a fresh derivation; the comparison is what must answer, NOT
	# the state hash (which also covers the block).
	var value_off := int(walk["first_value_off"])
	if value_off <= 0:
		_expect("scalar basis: the payload exposes the first row's value offset",
			false, str(value_off))
		return
	var damaged: PackedByteArray = payload.duplicate()
	damaged.encode_u8(value_off, damaged.decode_u8(value_off) ^ 0x01)
	var damaged_result: Dictionary = live_ext.restore_ideology_state(damaged)
	_expect("scalar basis: a scalar value the catalogs cannot rebuild is refused BY "
		+ "NAME (`ideology_save_scalar_basis_mismatch`, not a state-hash mismatch)",
		String(damaged_result.get("reason", ""))
			== "ideology_save_scalar_basis_mismatch",
		"ok=%s reason=%s" % [str(damaged_result.get("ok", "?")),
			String(damaged_result.get("reason", ""))])
	print("[basis/scalars] damaged value @%d -> ok=%s reason=%s"
		% [value_off, str(damaged_result.get("ok", "?")),
			String(damaged_result.get("reason", ""))])
	# (2) THE SAMPLE DAY IS HASHED. It takes part in no content comparison, so a rewrite
	# can only be caught by the state hash -- which is exactly what "it is in
	# compute_state_hash" means.
	var hash_off := 32   # magic 4, schema 4, catalog 8, day 8, order 8
	var skewed_day: PackedByteArray = payload.duplicate()
	skewed_day.encode_s64(int(tail["sample_day_off"]), payload_day + 999)
	var day_result: Dictionary = live_ext.restore_ideology_state(skewed_day)
	_expect("sample day: a rewritten sample day (+999) is caught by the STATE HASH, "
		+ "so the identity really is inside compute_state_hash()",
		String(day_result.get("reason", ""))
			== "ideology_save_state_hash_mismatch",
		"ok=%s reason=%s" % [str(day_result.get("ok", "?")),
			String(day_result.get("reason", ""))])
	# (3) ATOMICITY of the two §18.5 members. The damage is on the state hash, which the
	# reader checks AFTER the commit point, so the payload's block and day were already
	# assigned: a missing `rollback` entry would leave them behind. The payload's day is
	# moved 998 days away from the runtime's, so "unchanged" cannot be confused with
	# "nothing would have changed".
	var late: PackedByteArray = payload.duplicate()
	late.encode_s64(int(tail["sample_day_off"]), payload_day + 998)
	late.encode_u64(hash_off, late.decode_u64(hash_off) ^ 1)
	var late_result: Dictionary = live_ext.restore_ideology_state(late)
	_expect("scalar atomicity: the late-damaged payload is refused at the state hash "
		+ "(after the §18.5 commit point)",
		String(late_result.get("reason", "")) == "ideology_save_state_hash_mismatch",
		"ok=%s reason=%s" % [str(late_result.get("ok", "?")),
			String(late_result.get("reason", ""))])
	var after_report: Dictionary = live_ext.get_ideology_report()
	_expect("scalar atomicity: the scalar record (%d rows, first value %d) is UNCHANGED "
		% [rows_before, value_before]
		+ "by that refusal -- rollback, not half-write",
		int(after_report.get("local_scalar_basis_rows", -2)) == rows_before
			and int(after_report.get("local_scalar_basis_first_value", 0))
				== value_before,
		"rows %d->%d value %d->%d" % [rows_before,
			int(after_report.get("local_scalar_basis_rows", -2)), value_before,
			int(after_report.get("local_scalar_basis_first_value", 0))])
	_expect("scalar atomicity: the sample day is UNCHANGED by that refusal",
		int(after_report.get("derived_basis_sample_day", -3)) == day_before,
		"%d->%d" % [day_before,
			int(after_report.get("derived_basis_sample_day", -3))])
	_expect("scalar atomicity: the payload really did carry %d scalar rows and day "
		% int(walk["rows"])
		+ "%d, so the assignment above was not a no-op" % (payload_day + 998),
		int(walk["rows"]) >= 1 and rows_before == 0,
		"payload_rows=%d runtime_rows=%d" % [int(walk["rows"]), rows_before])
	_expect("scalar atomicity: the runtime's own capture is still BYTE-IDENTICAL "
		+ "after the three refusals",
		live_ext.capture_ideology_state() == capture_before,
		"%d vs %d bytes" % [live_ext.capture_ideology_state().size(),
			capture_before.size()])


## Walks the plan-18.5 local scalar block from its start: `u32 count` then `count` rows
## of `u64 country_handle + i32 metric_id + i64 value_q16`, no variable part.
func _walk_scalar_block(bytes: PackedByteArray, block_off: int) -> Dictionary:
	var out := {"rows": 0, "end": block_off, "error": "", "nonzero": 0,
		"foreign_handles": 0, "ascending": true, "first_metric": -1,
		"first_value": 0, "first_value_off": -1}
	if block_off < 0 or block_off + 4 > bytes.size():
		out["error"] = "count_unreadable"
		return out
	var count: int = int(bytes.decode_u32(block_off))
	out["rows"] = count
	var cursor: int = block_off + 4
	var previous_handle := -1
	var previous_metric := -1
	var first_handle := -1
	for index in range(count):
		if cursor + 20 > bytes.size():
			out["error"] = "row_unreadable@%d" % index
			return out
		var handle: int = int(bytes.decode_u64(cursor))
		var metric: int = int(bytes.decode_s32(cursor + 8))
		var value_off: int = cursor + 12
		var value: int = int(bytes.decode_s64(value_off))
		if index == 0:
			first_handle = handle
			out["first_metric"] = metric
			out["first_value"] = value
			out["first_value_off"] = value_off
		if handle != first_handle:
			out["foreign_handles"] = int(out["foreign_handles"]) + 1
		if handle < previous_handle or (handle == previous_handle
				and metric <= previous_metric):
			out["ascending"] = false
		if value != 0:
			out["nonzero"] = int(out["nonzero"]) + 1
		previous_handle = handle
		previous_metric = metric
		cursor += 20
	out["end"] = cursor
	return out



## A configured runtime with the same Effect/Modifier catalogs and the given ideology
## catalog. Deliberately minimal -- no economy, no territory, no country -- because the
## basis comparison is a catalog-only question and a fuller world would only add ways to
## fail earlier for unrelated reasons.
func _build_basis_runtime(ideology_catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELLS)
	_expect("basis runtime: the Effect catalog configures",
		bool(ext.configure_effects(_catalogs["effect_ir"]).get("ok", false)))
	_expect("basis runtime: the Modifier catalog configures",
		bool(ext.configure_modifiers(_catalogs["mod_ir"], CELLS).get("ok", false)))
	_expect("basis runtime: the IDEOLOGY catalog is ACCEPTED (a program assignment is "
		+ "not cross-checked against the level table)",
		bool(ext.configure_ideologies(ideology_catalog).get("ok", false)))
	return ext


## Duplicates the compiled ideology catalog and moves ONE level -> program assignment.
##
## `persistent_definition_keys` is not part of `compute_catalog_hash`, so the resulting
## runtime agrees with the original on the catalog hash, on the execution contract and on
## every persisted scalar; only the applied-program basis can tell them apart.
func _remap_program_catalog(from_key: String, to_key: String) -> Dictionary:
	var catalog: Dictionary = _catalogs["native_ideology"].duplicate(true)
	var keys: PackedStringArray = catalog.get("persistent_definition_keys",
		PackedStringArray())
	var at: int = keys.find(from_key)
	if at < 0 or keys.find(to_key) < 0:
		return {"moved": 0}
	keys[at] = to_key
	catalog["persistent_definition_keys"] = keys
	return {"moved": 1, "catalog": catalog, "index": at}


## Derives the PKID TAIL from the END of the payload (plan 18.2 added a variable-length
## block between the command table and the two basis dates, so the tail is the only part
## that can be addressed without re-implementing the whole reader).
##
## Layout, byte by byte from the end (v14):
##   size-4                  u32 SAVE_END
##   size-4-8                u64 execution contract
##   size-4-8-16             i64 confirmed_day, then i64 eligible_from_day
##   ...-8                   i64 sample_day (plan 18.5: the projection's sample day)
##   ...-4                   u32 scalar-basis block length (count field + rows)
##   that offset - length    the scalar block: u32 row count, then 20-byte rows
##   block start - 4         u32 applied-basis block length (count field + rows)
##   that offset - length    the applied block: u32 row count, then the rows
##   block start - 8         u64 pending command count
##
## The plan-18.5 additions sit BETWEEN the two §9.3 dates and the applied block, i.e.
## in FRONT of every field that was already addressed from the end, so the two dates and
## the contract keep their distance from SAVE_END. Only the applied block's length field
## moved: it is now reached by walking back THROUGH the scalar block, which is why this
## chain reads the scalar block's own length first.
func _pkid_tail(bytes: PackedByteArray) -> Dictionary:
	const CONTRACT_BYTES := 8
	const DATES_BYTES := 16
	const SAMPLE_DAY_BYTES := 8
	const LEN_BYTES := 4
	# u64 country_handle + i32 metric_id + i64 value_q16: no variable part.
	const SCALAR_ROW_BYTES := 20
	var size: int = bytes.size()
	var out := {"size": size, "basis_block_off": -1, "basis_len_off": -1,
		"basis_row_count": -1, "basis_block_bytes": -1, "contract_off": -1,
		"dates_off": -1, "sample_day_off": -1, "sample_day": 0,
		"scalar_len_off": -1, "scalar_block_off": -1, "scalar_block_bytes": -1,
		"scalar_row_count": -1, "scalar_rows_end": -1}
	var contract_off: int = size - 4 - CONTRACT_BYTES
	var dates_off: int = contract_off - DATES_BYTES
	var sample_day_off: int = dates_off - SAMPLE_DAY_BYTES
	var scalar_len_off: int = sample_day_off - LEN_BYTES
	out["contract_off"] = contract_off
	out["dates_off"] = dates_off
	out["sample_day_off"] = sample_day_off
	out["scalar_len_off"] = scalar_len_off
	if scalar_len_off < 40:
		return out
	out["sample_day"] = int(bytes.decode_s64(sample_day_off))
	var scalar_bytes: int = int(bytes.decode_u32(scalar_len_off))
	out["scalar_block_bytes"] = scalar_bytes
	var scalar_off: int = scalar_len_off - scalar_bytes
	out["scalar_block_off"] = scalar_off
	if scalar_bytes < 4 or scalar_off < 40:
		return out
	var scalar_rows: int = int(bytes.decode_u32(scalar_off))
	out["scalar_row_count"] = scalar_rows
	out["scalar_rows_end"] = scalar_off + 4 + scalar_rows * SCALAR_ROW_BYTES
	var len_off: int = scalar_off - LEN_BYTES
	out["basis_len_off"] = len_off
	if len_off < 40:
		return out
	var block_bytes: int = int(bytes.decode_u32(len_off))
	out["basis_block_bytes"] = block_bytes
	out["basis_block_off"] = len_off - block_bytes
	if block_bytes >= 4 and int(out["basis_block_off"]) >= 40:
		out["basis_row_count"] = int(bytes.decode_u32(int(out["basis_block_off"])))
	return out


## Walks the applied-basis block row by row from its start, so the caller can prove the
## block's declared length is the truth about its contents.
func _walk_basis_block(bytes: PackedByteArray, block_off: int) -> Dictionary:
	var out := {"rows": 0, "end": block_off, "first_program_key": "",
		"first_selector_kind": -1, "first_terms_digest": 0, "first_digest_off": -1,
		"error": ""}
	if block_off < 0 or block_off + 4 > bytes.size():
		out["error"] = "count_unreadable"
		return out
	var count: int = int(bytes.decode_u32(block_off))
	out["rows"] = count
	var cursor: int = block_off + 4
	for index in range(count):
		if cursor + 12 > bytes.size():
			out["error"] = "row_handle_unreadable@%d" % index
			return out
		cursor += 8                                    # country handle
		var key_len: int = int(bytes.decode_u32(cursor))
		cursor += 4
		if key_len > 512 or cursor + key_len + 12 > bytes.size():
			out["error"] = "row_key_invalid@%d" % index
			return out
		var program_key := bytes.slice(cursor, cursor + key_len).get_string_from_utf8()
		cursor += key_len
		var selector_kind: int = int(bytes.decode_s32(cursor))
		cursor += 4
		var id_len: int = int(bytes.decode_u32(cursor))
		cursor += 4
		if id_len > 512 or cursor + id_len + 20 > bytes.size():
			out["error"] = "row_selector_id_invalid@%d" % index
			return out
		cursor += id_len
		cursor += 4                                    # selector_param[0]
		cursor += 4                                    # selector_param[1]
		var digest_off: int = cursor
		var terms_digest: int = int(bytes.decode_u64(cursor))
		cursor += 8
		if index == 0:
			out["first_program_key"] = program_key
			out["first_selector_kind"] = selector_kind
			out["first_terms_digest"] = terms_digest
			out["first_digest_off"] = digest_off
	out["end"] = cursor
	return out


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
## fixture satisfies (two cohorts of 20 each). The shipped predicate reads building
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
# world construction (identical for every branch)
# =========================================================================

## `economy_days` economy days are committed, each under its OWN input epoch
## (`epoch_id == day + 1`, `sample_day == day`), and every epoch is verified to have
## CLOSED (`epoch_active == false`) before the next one opens. That is what "the new
## epoch" means here, and it is the epoch the derived basis is adopted under.
##
## The days run BEFORE any card exists on every branch, so every world starts from a
## bit-identical economy and no economy day ever runs with a different derived front
## on the two sides of a comparison.
func _new_world(label: String, economy_days: int) -> Dictionary:
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
		"country_ids": PackedStringArray(["country.sv56"]),
		"country_names": PackedStringArray(["Save Point Five"]),
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

	# DUPLICATED IMMEDIATELY: `begin_or_reuse_economy_input_epoch` returns a
	# Dictionary that shares storage with the runtime's cached input-capture report
	# (`world_ext_economy.cpp:680` hands back `_economy_capture_cached_report` by
	# reference). The very next `run_economy_slice` for the same day rewrites that
	# cache in place, so a value kept without a copy reports the CACHE's later
	# contents -- measured: `ok` was present at the call and gone one day later.
	var epoch1: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, {
		"sample_day": 0, "epoch_id": 1, "map_generation": 1,
		"building_generation": 1, "country_generation": 1,
		"resource_generation": 1}).duplicate(true)
	_expect("%s: epoch 1 opens for day 0" % label, bool(epoch1.get("ok", false)),
		str(epoch1.get("reason", epoch1.get("fatal_reason", "?"))))

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
	var slices := _advance_economy_day(ext, 0, label)
	_expect("%s: economy day 0 reaches its committed boundary" % label,
		slices > 0, str(slices))

	var epoch2: Dictionary = {}
	for day in range(1, economy_days):
		# A NEW epoch for the new day: different `sample_day` and `epoch_id`, so the
		# runtime cannot reuse the previous day's frozen input generation.
		epoch2 = ext.begin_or_reuse_economy_input_epoch(day, {
			"sample_day": day, "epoch_id": day + 1, "map_generation": 1,
			"building_generation": 1, "country_generation": 1,
			"resource_generation": 1}).duplicate(true)
		print("[world/%s] epoch day=%d ok=%s captured=%s reused=%s"
			% [label, day, str(epoch2.get("ok", "?")),
				str(epoch2.get("captured", "?")),
				str(epoch2.get("input_capture_reused", "?"))])
		var day_slices := _advance_economy_day(ext, day, label)
		_expect("%s: economy day %d commits under its own epoch" % [label, day],
			day_slices > 0, str(day_slices))

	var handle := int(ext.get_country_cell_summary(owned_cells[0]).get(
		"country_handle", 0))
	_expect("%s: the fixture resolves the country handle" % label, handle != 0,
		str(handle))
	var economy: Dictionary = ext.get_economy_report()
	return {
		"label": label, "ext": ext, "handle": handle,
		"owned": owned_cells.size(), "owned_cells": owned_cells,
		"epoch_active": bool(economy.get("epoch_active", true)),
		"newest_state_day": int(economy.get("newest_state_day", -1)),
		# DUPLICATED on purpose: `begin_or_reuse_economy_input_epoch` hands back a
		# Dictionary that shares storage with its cached report
		# (`world_ext_economy.cpp:680` returns a copy of `_economy_capture_cached_report`
		# by reference), so keeping the raw value alive and reading it later reports
		# the CACHE's current contents, not this call's result.
		"epoch1": epoch1.duplicate(true), "epoch2": epoch2.duplicate(true),
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


# =========================================================================
# ideology commands
# =========================================================================

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


# =========================================================================
# advancing
# =========================================================================

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage: a
## single call may come back `done=false` with the day (or the derived rebuild) still
## in progress, so looping on the runtime's own `done` flag is what lets this fixture
## wait honestly instead of guessing a call count.
##
## Calling it AGAIN for a day that already reported `done` is deliberate, and it is
## what the `settle` passes do: the second pass re-runs the derived rebuild against
## the basis that has since been CONFIRMED (the transition poll at
## `ideology_runtime.cpp:4954-4968` runs before the collect) and starts no new work
## of the day itself -- commands are already consumed, understanding accrual is
## guarded by `_last_day < day` and points are settled once per committed economy
## day. Every branch performs the same number of passes for the same day index, so
## nothing is desynchronised by it; the day index is never moved BACKWARDS.
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
# state capture + comparison
# =========================================================================

## `expect_front` decides what the layer MUST look like at this point: an installed
## front covering `owned * 2` (stat, cell) contributions, or the explicit empty
## result the runtime installs when a card stops contributing
## (`modifier_runtime.cpp:1670-1677`). `program_key` is the level program whose
## magnitude the covered cells must carry, read from the interpreter rather than
## hard-coded.
func _capture_state(world: Dictionary, label: String, expect_front: bool,
		expected_day: int, program_key: String) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var cells := {}
	for stat in [STAT_ADD, STAT_CUT]:
		cells[stat] = _probe_all_cells(ext, stat)
	var layer_cells := int(layer.get("cell_count", 0))
	var expected_layer_cells := 2 * int(world["owned"])
	if expect_front:
		# THE "the layer really came back" assertion. PKID does not carry the front,
		# so a non-zero, exactly right cell count can only come from a rebuild.
		_expect("%s: the runtime HAS a derived cell layer" % label,
			bool(layer.get("installed", false)) and layer_cells > 0,
			"installed=%s cells=%s" % [str(layer.get("installed", "?")),
				str(layer_cells)])
		_expect("%s: the layer covers exactly the owned cells x 2 stats" % label,
			layer_cells == expected_layer_cells,
			"%d vs %d" % [layer_cells, expected_layer_cells])
		_expect("%s: the layer carries the expected contribution count" % label,
			int(layer.get("contribution_count", 0)) == expected_layer_cells,
			"%d vs %d" % [int(layer.get("contribution_count", 0)),
				expected_layer_cells])
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
		var cut_probe: Dictionary = ext.get_effective_stat_value(
			STAT_CUT, covered_cell, 0, 1.0)
		_expect("%s: the .cut command's derived delta is NEGATIVE" % label,
			bool(cut_probe.get("derived_present", false))
			and float(cut_probe.get("derived_add", 0.0)) < 0.0, str(cut_probe))
		# ABSOLUTE correctness, not just equality between two runs: the covered
		# cells must carry the LEVEL PROGRAM's own magnitude.
		var metrics := PackedInt64Array()
		metrics.resize(120)
		metrics.fill(0)
		var interp: Dictionary = ext.evaluate_effect_program_magnitude(
			program_key, metrics)
		var expected_add := float(int(interp.get("magnitude", 0))) / float(Q16_ONE)
		_expect("%s: the card's persistent program (%s) evaluates"
			% [label, program_key], bool(interp.get("ok", false)), str(interp))
		var covered_add := float(covered_probe.get("derived_add", 0.0))
		_expect("%s: the covered add equals %s / Q16 (%.8f)"
			% [label, program_key, expected_add],
			absf(covered_add - expected_add) <= 1e-6,
			"derived=%.8f expected=%.8f" % [covered_add, expected_add])
	else:
		_expect("%s: the layer is the explicit EMPTY result (card not contributing)"
			% label,
			not bool(layer.get("installed", true)) and layer_cells == 0,
			"installed=%s cells=%s" % [str(layer.get("installed", "?")),
				str(layer_cells)])

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
		"layer_stat_ids": (layer.get("stat_ids", PackedInt32Array())
			as PackedInt32Array).duplicate(),
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
		"audit": audit,
		"economy_newest_day": int(economy.get("newest_state_day", -1)),
		"economy_committed_day": int(audit.get("day", -1)),
		"fingerprint": "",
	}
	out["fingerprint"] = _fingerprint(cells)
	print("[sv/%s] layer cells=%d contributions=%s stats=%s day=%s generation=%s"
		% [label, layer_cells, str(layer.get("contribution_count", "?")),
			str(layer.get("stat_count", "?")), str(layer.get("sample_day", "?")),
			str(layer.get("layer_generation", "?"))])
	print("[sv/%s] card locations=%s levels=%s understanding=%s "
		% [label, str(snapshot.get("locations", "?")),
			str(snapshot.get("levels", "?")),
			str(snapshot.get("understanding_q16", "?"))]
		+ "pending_commands=%s pending_transitions=%s"
		% [str(report.get("pending_commands", "?")),
			str(report.get("pending_transitions", "?"))])
	print("[sv/%s] economy newest_state_day=%s committed_day=%s instances=%d"
		% [label, str(economy.get("newest_state_day", "?")),
			str(audit.get("day", "?")), int(instances.get("count", -1))])
	print("[sv/%s] business hash=%s points=%s ideas=%s"
		% [label, str(business.get("hash", "?")), str(business.get("points", "?")),
			str(business.get("ideas", "?"))])
	print("[sv/%s] audit available=%s pop_err=%s money_err=%s goods_err=%s"
		% [label, str(audit.get("available", false)),
			str(audit.get("population_error", "?")),
			str(audit.get("money_error", "?")),
			str(audit.get("goods_error", "?"))])
	print("[sv/%s] per-cell fingerprint=%s" % [label, out["fingerprint"]])
	_expect("%s: the economy reached the expected committed day" % label,
		int(economy.get("newest_state_day", -1)) == expected_day,
		"%s vs %d" % [str(economy.get("newest_state_day", "?")), expected_day])
	return out


## The add every covered cell must carry, taken from the first owned cell of the
## first stat's probe row -- used to compare one LEVEL's content against another's.
func _covered_add(state: Dictionary) -> float:
	var first_owned := 0
	var present: PackedByteArray = (state["cells"][STAT_ADD] as Dictionary)["present"]
	for c in range(present.size()):
		if present[c] != 0:
			first_owned = c
			break
	return float((state["cells"][STAT_ADD] as Dictionary)["add"][first_owned])


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


## The 11.7 comparison itself. Deliberately does NOT compare `sample_day`: the front
## is not part of PKID, so a reload rebuilds it and legitimately installs on a
## different day than the continuous run did. The install COUNT
## (`layer_generation`) IS compared, because both fronts start from generation 0.
func _compare(reference: Dictionary, other: Dictionary, tag: String,
		expected_pending: int) -> void:
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
	# The front's SHAPE, not only its numbers: a dropped stat row or a shifted cell
	# index would otherwise be invisible on cells that carry 0 either way.
	_expect("%s: the layer covers the same cells and the same stats" % tag,
		int(reference["layer"]["cell_count"]) == int(other["layer"]["cell_count"])
		and int(reference["layer"]["contribution_count"])
			== int(other["layer"]["contribution_count"])
		and int(reference["layer"]["stat_count"])
			== int(other["layer"]["stat_count"])
		and str(reference["layer_stat_ids"]) == str(other["layer_stat_ids"]),
		"cells %s/%s contribs %s/%s stats %s/%s ids %s/%s" % [
			str(reference["layer"].get("cell_count", "?")),
			str(other["layer"].get("cell_count", "?")),
			str(reference["layer"].get("contribution_count", "?")),
			str(other["layer"].get("contribution_count", "?")),
			str(reference["layer"].get("stat_count", "?")),
			str(other["layer"].get("stat_count", "?")),
			str(reference["layer_stat_ids"]), str(other["layer_stat_ids"])])
	_expect("%s: both runs installed the layer the same number of times" % tag,
		int(reference["layer_generation"]) == int(other["layer_generation"]),
		"%d vs %d" % [int(reference["layer_generation"]),
			int(other["layer_generation"])])
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
	# One-shot execution counts: a derived card must create ZERO Effect instances in
	# both runs (I01), and both runs must have the same number of unapplied commands
	# (0 once the change has landed, 1 while it is queued).
	_expect("%s: one-shot effect instance count is 0 in both runs" % tag,
		int(reference["instances"]) == 0 and int(other["instances"]) == 0,
		"%d vs %d" % [int(reference["instances"]), int(other["instances"])])
	_expect("%s: both runs carry the same pending command count (%d)"
		% [tag, expected_pending],
		int(reference["snapshot"]["pending_commands"]) == expected_pending
		and int(other["snapshot"]["pending_commands"]) == expected_pending,
		"%d vs %d" % [int(reference["snapshot"]["pending_commands"]),
			int(other["snapshot"]["pending_commands"])])
	_expect("%s: both runs carry the same in-flight transition count" % tag,
		int(reference["snapshot"]["pending_transitions"])
		== int(other["snapshot"]["pending_transitions"]),
		"%d vs %d" % [int(reference["snapshot"]["pending_transitions"]),
			int(other["snapshot"]["pending_transitions"])])
	_expect("%s: both runs advanced the economy to the same committed day" % tag,
		int(reference["economy_newest_day"]) == int(other["economy_newest_day"])
		and int(reference["economy_committed_day"])
			== int(other["economy_committed_day"]),
		"newest %d/%d audit %d/%d" % [
			int(reference["economy_newest_day"]),
			int(other["economy_newest_day"]),
			int(reference["economy_committed_day"]),
			int(other["economy_committed_day"])])
	_expect("%s: the card's IDEOLOGY slot occupancy matches" % tag,
		_active_locations(reference["snapshot"]) == _active_locations(
			other["snapshot"]),
		"%d vs %d" % [_active_locations(reference["snapshot"]),
			_active_locations(other["snapshot"])])
	_expect("%s: the card keeps the same level and understanding" % tag,
		str(reference["snapshot"]["levels"]) == str(other["snapshot"]["levels"])
		and str(reference["snapshot"]["understanding_q16"])
			== str(other["snapshot"]["understanding_q16"]),
		"%s / %s vs %s / %s" % [
			str(reference["snapshot"]["levels"]),
			str(reference["snapshot"]["understanding_q16"]),
			str(other["snapshot"]["levels"]),
			str(other["snapshot"]["understanding_q16"])])
	# Economy conservation (11.7 compares it at every time point).
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


func _ascii_magic(bytes: PackedByteArray) -> String:
	return bytes.slice(0, mini(4, bytes.size())).get_string_from_ascii()


## Every check is printed, pass or fail: 11.7 evidence is the LIST of things that
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
	print("=== ideology save basis + mid-materialize (11.7 time points 5 and 6): "
		+ "%d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
