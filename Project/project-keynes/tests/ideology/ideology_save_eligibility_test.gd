extends SceneTree
## 11.7 time points 3 and 4:
##
##   TP3  "confirmed but not yet at the eligibility day"
##   TP4  "the eligibility day has arrived but the old epoch has not ended"
##
## WHAT THE PLAN DEMANDS (22-cell-program-cap-removal-plan-v3.md:799-809)
##
##   Every time point compares a CONTINUOUS run against the same run after
##   save -> reload on the per-cell effective factors, the economy conservation
##   result, the one-shot execution counts and the business state. A fresh-world
##   roundtrip alone does not pass.
##
## THE MECHANISMS THIS FIXTURE IS BUILT ON
##
##   The plan's own vocabulary is now IN the shipped runtime: plan §9.3
##   (`22-cell-program-cap-removal-plan-v3.md:589-597`) says a structural change
##   that receives its required ACKs on business day D is CONFIRMED on D, its
##   projection is `eligible_from_day = D + 1`, and a freeze boundary with
##   `sample_day = S` may only pick a confirmed projection with
##   `eligible_from_day <= S`. `NativeIdeologyRuntime` implements exactly that
##   (`confirmed_day` / `eligible_from_day`, `ideology_runtime.cpp:3845-3846`;
##   the refusal in `step_derived_rebuild`, `:7040-7048`). What the runtime has on
##   top of it is the command queue and the economy freeze boundary, and the three
##   together are what the two time points below live on.
##
##   MECHANISM 1 -- the ELIGIBILITY DAY of an admitted command (time point 3).
##     `NativeIdeologyRuntime::submit_commands` (ideology_runtime.cpp:4749) only
##     validates the SHAPE of a command row and appends it to `_commands` with
##     its own `effective_day` (:4762, persisted at :6495). It is applied only
##     once the business day reaches that day:
##         ::run_daily_slices  ideology_runtime.cpp:4936
##             `while (command != nullptr && command->effective_day <= day)`
##     So a command submitted with `effective_day = D + 2` is ADMITTED and
##     durably stored (`pending_commands == 1`, written into PKID), and changes
##     nothing at all until day D + 2. That is "confirmed but not yet at the
##     eligibility day" in the form the command queue implements it.
##
##   MECHANISM 1b -- THE CONFIRMATION DAY OF THE DERIVED PROJECTION (§9.3).
##     The equip's structural Effect transaction can only be confirmed after the
##     slice that started it returned, i.e. one slice later. When
##     `poll_pending_transition` observes every required ACK on day D it records
##     `confirmed_day = D`, `eligible_from_day = D + 1` (:3845-3846) and
##     `step_derived_rebuild(D, ...)` REFUSES to rebuild: the guard at :7045-7048
##     returns before the collect step and counts the refusal in
##     `derived_rebuild_gated_by_eligibility`. So on the equip day the front the
##     confirmed projection should produce is NOT published, and it appears on
##     D + 1 -- one business day after the confirmation, as the plan asks.
##
##     THAT IS A REAL TIME POINT, NOT A DELAY TO PAPER OVER. Plan §11.7 lists
##     "confirmed, but not yet at the eligibility day" as its own save moment
##     (:803 of 22-cell-program-cap-removal-plan-v3.md), and :719 requires the save
##     to carry
##     `confirmed_day` / `eligible_from_day` precisely so a reader can tell which
##     projections are not eligible yet.
##
##     THIS FIXTURE NOW SAVES AT BOTH MOMENTS. It asserts the state on the equip day
##     (TP4-confirmed) AND takes a save point there (`SAVE-TP4-confirmed`), because
##     PKID schema 11 persists the pair -- see "WHAT THE SCHEMA 11 FIX CHANGED"
##     below. TP4 stays the second, later save point, taken on the eligibility day.
##
##   MECHANISM 2 -- the ECONOMY FREEZE BOUNDARY (time point 4).
##     The derived front is rebuilt and installed once per ideology day
##     (`step_derived_rebuild`, ideology_runtime.cpp:6978; the install is
##     :7100-7104) and it is installed for the day it was built FOR
##     (`sample_day`, :7051-7053). A consumer only ADOPTS it at an economy
##     freeze boundary:
##         ::start_epoch            economy_runtime_epoch.cpp:816
##           -> capture_country_epoch  economy_runtime.cpp:4967
##             -> refresh_city_modifier_factors  economy_runtime.cpp:6997
##                  reads ModifierRuntime::effective_value per cell, which is
##                  where the derived front is merged (modifier_runtime.cpp:1462)
##                  and freezes it into `_epoch_cell_birth_factor_q16` (:7070)
##     An epoch that is already OPEN keeps the matrix it froze. So on the day the
##     card becomes eligible the front carries the card while the epoch opened for
##     it still runs on pre-card factors: the change is adopted at the NEXT
##     boundary. That is "the eligibility day has arrived but the old epoch has not
##     ended".
##
##     PARKING THE EPOCH. "Old epoch still open" only exists between
##     `start_epoch` and the day's COMMIT, and a normal slice runs the whole day
##     in one call. The slice budget is a context argument
##     (economy_runtime.cpp:15155) checked right AFTER the epoch opens (:15376),
##     so handing it the minimum (`slice_budget_ms = 0.1`) stops the day inside
##     its own epoch. `_open_epoch` then verifies the park from the report
##     (`epoch_active == true`, `sample_day == D`, `last_committed_day == D - 1`)
##     instead of assuming it.
##
## WHAT THIS FIXTURE DOES
##
##   One continuous timeline is built from scratch (8x8 = 64 cells, one country
##   owning a scattered 2/3 of them, one kind-12 derived card). GRANT and
##   DISCOVER are due on day 0, and the EQUIP is submitted with
##   `effective_day = ELIGIBILITY_DAY` (2) at the same time, so the run walks two
##   business days across the eligibility boundary:
##
##     submit    GRANT(day 0) + DISCOVER(day 0) + EQUIP(effective day 2)
##     day 1     economy commits day 1 (no epoch left open)
##     day 0     GRANT + DISCOVER apply; the equip is not due yet
##     day 1     the equip is still not due
##     ====== SAVE-TP3 ======  pending_commands == 1, card INACTIVE, front EMPTY,
##                             no projection confirmed yet (both basis dates -1)
##     day 2     the epoch for day 2 opens (front still empty -> pre-adoption
##               factors freeze), THEN the equip applies and its structural Effect
##               transaction is ACKed and settles. The settle records
##               confirmed_day == 2 / eligible_from_day == 3, and day 2's rebuild
##               is REFUSED by the §9.3 gate: an un-ACKed equip contributes
##               NOTHING (plan 10.1) and a confirmed one may not be adopted on its
##               confirmation day (§9.3), so the front is STILL EMPTY.
##     ====== TP4-confirmed ======  epoch_active == true / sample_day == 2 /
##                             last_committed_day == 1 / confirmed 2 / eligible 3 /
##                             gated > 0 / front STILL EMPTY
##     ====== SAVE-TP4-confirmed ======  PKEF + PKID captured HERE. The pair (2 / 3)
##                             is IN the payload and the front is still empty. A
##                             runtime restored from it has to refuse to adopt on day
##                             2 and adopt on day 3, exactly like this run.
##     day 3     the FIRST day the confirmed projection is eligible. Its rebuild
##               collects the confirmed basis and INSTALLS the front for
##               sample_day == 3. Nothing of day 2 is redone: its commands are
##               consumed, its understanding accrual is guarded by
##               `_last_day < day`, and points settle per committed economy day.
##     ====== SAVE-TP4 ======  epoch_active == true / sample_day == 2 /
##                             last_committed_day == 1, front sample_day == 3
##     day 2/3   day 2 commits, the day-3 boundary re-freezes the matrix with the
##               card (the adoption), the front content is unchanged so no new
##               install happens
##
##   The two time points are therefore DIFFERENT moments on purpose: TP4-confirmed
##   is "the projection is confirmed but not eligible" (plan :803), and since PKID
##   schema 11 it is a REAL save point -- a payload captured there restores with both
##   dates and still refuses to adopt. TP4 is "the eligibility day has arrived and
##   the projection is adopted while the old epoch is still open" (plan :804).
##
##   From each save point the SAME continuation is run twice:
##
##     * continuous -- the original runtime keeps going;
##     * reload     -- a NEW DCWorldExt is built from the same bootstrap, the
##                     save payload is restored into it, and it runs the same
##                     days with the same command batches (identical idempotency
##                     keys).
##
##   The two sides are compared CELL BY CELL through `get_effective_stat_value`
##   on two stats (one positive card command, one negative ".cut" command), on
##   the business state, the one-shot counters and the economy audit.
##
## THE PAYLOAD IS PKEF + PKID, NOT PKID ALONE
##
##   `NativeIdeologyRuntime::restore` verifies that every equipped idea's external
##   Effect binding still exists (ideology_runtime.cpp:6793-6812) and rejects the
##   payload with `ideology_effect_binding_missing_or_mismatched` otherwise. That
##   was hit for real here: restoring the TP4 payload into a fresh runtime by
##   PKID ALONE failed with exactly that reason and the card came back
##   unequipped. The payload is therefore `capture_effect_state()` +
##   `capture_ideology_state()`, restored in that order -- the order
##   `game_save_coordinator` uses (plan 11.4 lists PKEF before PKID).
##
## TWO THINGS THE FIXTURE HAS TO PLAY ITSELF
##
##   1. THE ACKER. An equip starts a structural Effect transaction and
##      `poll_pending_transition` only settles it once every id answers ACKED.
##      With no runtime host nothing acks, so the fixture drives the public peer
##      lifecycle (poll -> preflight -> commit -> ack) exactly as
##      `tests/effect/effect_runtime_test.gd:130-151` does. Without this the
##      card would sit in a pending transition forever, and a pending transition
##      is precisely what a PKID payload cannot restore on its own.
##   2. THE ECONOMY HALF. PKID carries ideology state only, so the reload branch
##      replays the same committed economy days before restoring. That is the
##      fixture standing in for the ECP2 section (production restores ECP2 before
##      PKID); this fixture does not exercise ECP2 and nothing here claims the
##      mid-epoch frozen matrix survives a real save. The replayed economy is
##      then held to the same standard as everything else: the final
##      `get_economy_state_hash()` must be identical on every branch.
##
## AND THE ORDER THE FIXTURE HAD TO MOVE (plans 10.1 and 9.3)
##
##   Reading the derived layer right after the equip is not a valid observation any
##   more, twice over. A card whose equip transition is not ACKed contributes
##   NOTHING (`collect_effect_activations`, `ideology_runtime.cpp:2317-2318`); the
##   ACK can only exist after the slice that started the transaction returned, and
##   that same slice already ran the day's COLLECT step. And even once the ACK is
##   polled, §9.3 refuses to adopt the projection on its confirmation day
##   (`:7090-7101`). `_settle_confirmation` therefore does what the plan asks:
##   re-enter the SAME day once so `run_ideology_daily` polls `_pending_transitions`
##   first (`:4954-4968`) and settles it, and assert the refusal. `_publish_eligible_day`
##   then runs the ELIGIBILITY day (D + 1), whose rebuild is the first one allowed to
##   publish the confirmed basis. Neither pass starts new work of its day: the day's
##   commands are consumed, its understanding accrual is guarded by `_last_day < day`
##   (`:5019`) and its points settle once per committed economy day. Day indices
##   never move backwards; re-entering the same day is legal -- which is also what
##   makes the SAVE-TP4-confirmed reload below able to re-enter the confirmation day
##   on a restored runtime and prove the gate refuses there too.
##
## WHAT THE SCHEMA 11 FIX CHANGED (and what this fixture adds because of it)
##
##   Until PKID schema 10 the pair `confirmed_day` / `eligible_from_day` was exposed
##   by `get_ideology_report()` but NOT persisted, so a payload taken while a basis
##   was confirmed-but-not-eligible reloaded as -1 / -1: no gate, and the restored
##   runtime would have adopted the projection on its CONFIRMATION day, one business
##   day early. That is why this fixture used to assert that moment from a live
##   runtime only and to move its save point to the eligibility day.
##
##   Schema 11 writes the pair after every variable-length section and before the
##   trailer (`ideology_runtime.cpp:6642-6647`), covers it with the state hash
##   (`:6482-6490`), validates it as a PAIR (`:6857-6860`) and rolls it back with
##   every other restore field. Schema 12 keeps that pair and appends ONE more field
##   after it -- the plan 11.5 execution-contract identity (u64) -- so the pair is no
##   longer the last 16 bytes before SAVE_END; see the PKID tail constants below.
##   So `SAVE-TP4-confirmed` is now an honest save
##   point and the missing direction is testable:
##
##     * the payload physically carries the pair (decoded from the two s64 slots
##       before the contract u64 and SAVE_END, and matched against the live report of
##       the writer),
##     * a restored runtime comes back with the SAME pair,
##     * the restored front is still the previous (empty) one, and re-entering the
##       CONFIRMATION day on the restored runtime is REFUSED by the §9.3 gate,
##     * the eligibility day then adopts exactly what the continuous run adopted
##       (same `sample_day`, same `layer_generation`, same per-cell fingerprint).
##
##   AND THE PAIR IS PROVEN LOAD-BEARING, not decoration (see
##   `_negative_basis_dates`): an ILLEGAL pair is refused with
##   `ideology_save_basis_dates_invalid`, including `eligible == confirmed`, which is
##   the removed failure mode written as a pair; a LEGAL but wrong pair is refused
##   EARLIER still, by the state hash, because the dates are hashed -- so a payload's
##   dates cannot be rewritten at all; and a genuine payload whose legal pair is one
##   day EARLIER ((1,2) instead of (2,3), captured from a second timeline whose equip
##   was submitted a day earlier) restores and adopts one day earlier than the
##   continuous run. That last measurement is the failure mode the fix removed.
##
##   NOTE ON DIRECTION, because the gate is monotone (`day < eligible_day`): a pair
##   shifted LATER can only DELAY adoption, never bring it forward. "One day early"
##   therefore has exactly one shape -- a legal pair one day EARLIER -- and it can
##   only be produced by a genuine save, which is what NEG-5 does. NEG-6 MEASURES the
##   other direction with a genuine pair one day LATER (adoption moves one day later),
##   so the direction claim is data, not inference.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_save_eligibility_test.gd

const WIDTH := 8
const HEIGHT := 8
## 8x8 keeps the fixture small; `c >> 3` is `c / 8` without an integer-division
## warning for the row index.
const ROW_SHIFT := 3
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261028
## A permanent cell card (kind 12 = SELECTOR_OWN_TERRITORY, lifecycle 0). Same
## card the B7 wide-territory fixture proves reaches the whole territory.
const CARD_KEY := "idea.public_hygiene"
## The card's two commands. The first resolves to ADD +1.0, the second (".cut")
## to ADD -1.0 with the SAME positive program magnitude -- comparing both proves
## the sign survives the reload as well as the value.
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const Q16_ONE := 65536
## The level-1 persistent program of the card. Its magnitude is what the covered
## cells' derived add must equal.
const PROGRAM_KEY := "ideology.effect.public_hygiene_l1"
## TIME POINT 3: the equip is submitted with this `effective_day` while the world
## is at day 0, so the world really walks two business days without applying it.
## This is the eligibility day of mechanism 1.
const ELIGIBILITY_DAY := 2
## THE §9.3 ELIGIBILITY DAY OF THE PROJECTION. The equip settles on
## ELIGIBILITY_DAY, so the resulting confirmation has
## `eligible_from_day = confirmed_day + 1` and day 3 is the first rebuild allowed
## to publish it. Derived, not hard-coded: if ELIGIBILITY_DAY moves, this moves.
const PROJECTION_ELIGIBLE_DAY := ELIGIBILITY_DAY + 1
## The last day both branches run. It is the first freeze boundary that can adopt
## the card (mechanism 2) AND the first day the confirmed projection is eligible
## (plan §9.3), which is why the two constants coincide.
const FINAL_DAY := 3
## `run_economy_slice` takes its budget from the context (`economy_runtime.cpp`
## :15155, clamped to [0.1, 8.0]). The minimum is used ONLY to park inside day 2's
## epoch so that "old epoch still open" is a real state and not a guess.
const EPOCH_PARK_BUDGET_MS := 0.1
## The PKID tail as PKID schema 13 writes it (`ideology_runtime.cpp:6642-6647`):
## `confirmed_day` (s64), `eligible_day` (s64), the plan 11.5 execution-contract
## identity (u64), then the 4-byte SAVE_END trailer. Every field is appended after
## every variable-length section, so the pair is addressable from the END of the
## payload without parsing the country rows in front of it -- but only by skipping
## EVERY trailing field.
##
## THE SKIP IS WHAT SCHEMA 12 CHANGED. Schema 11 had no contract u64, so
## `size - 4 - 16` really was the pair. From schema 12 that same expression lands on
## `eligible_day` (reads 3) and the contract u64 (reads 7666137605786472753), which is
## exactly the `payload=3/7666137605786472753 report=2/3` this fixture used to report.
## `PKID_CONTRACT_BYTES` keeps the offsets on the DATES, so the NEG mutants below
## still hit the date slots and still test `ideology_save_basis_dates_invalid`
## instead of accidentally rewriting the contract and testing
## `cell_program_execution_contract_mismatch`.
##
## Both numbers below are the writer's layout, not a re-derivation:
## `_pkid_basis_dates` asserts the trailer and `_reload_confirmed` asserts that the
## slot skipped here really is the runtime's own execution contract.
##
## SCHEMA 13 (plan 18.2) appends a variable-length applied-program basis block
## BEFORE the pair, closed by its own u32 byte length. The date slots are addressed
## from the END, so this fixture's offsets are UNCHANGED by that block -- which is
## exactly why the block carries a trailing length instead of being found by parsing
## the country rows. Only the version number moves.
##
## SCHEMA 14 (plan 18.5) appends the local scalar basis block and the projection's
## sample day, and BOTH sit BEFORE the pair for the same reason: the two dates keep
## their distance from the END (`size - 4 - 8 - 16`), so this fixture still does not
## need a tail walk. Everything new is behind the pair, where only the fixtures that
## walk it (robustness / basis / worker) need to look.
const PKID_OFF_SCHEMA := 4
const PKID_SCHEMA := 14
const PKID_TRAILER_BYTES := 4
## Plan 11.5: one u64 between the two basis dates and the trailer.
const PKID_CONTRACT_BYTES := 8
const PKID_BASIS_DATES_BYTES := 16
## The NEG-5 timeline: the SAME equip submitted for one day earlier, so its
## transition settles on day 1 and its legal pair is (1, 2) instead of (2, 3).
const EARLY_EQUIP_DAY := ELIGIBILITY_DAY - 1
## The NEG-6 timeline: the SAME equip submitted for one day LATER, so its legal pair
## is (3, 4). NEG-6 measures what a "+1" pair does -- it DELAYS adoption. That is why
## "shift both dates by +1 and adopt one day earlier" cannot be a real state, and why
## NEG-5 is the only shape "one day early" has.
const LATE_EQUIP_DAY := ELIGIBILITY_DAY + 1

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
var _effect_cursor := 0
var _effect_acked := 0
var _effect_ack_failures := 0


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
	# `sequences` is the idempotency key and the high watermark is part of PKID.
	var batches: Array = _batches(dense)

	# ── continuous timeline ───────────────────────────────────────────────
	var continuous: Dictionary = _new_world("continuous")
	_step_to_tp3(continuous, batches, "continuous")
	var tp3_payload: Dictionary = _capture(continuous["ext"], "TP3")
	_expect_tp3(continuous, "continuous", "TP3", 2)
	var tp4_from_continuous: Dictionary = _step_to_tp4(
		continuous, "continuous")
	var reference: Dictionary = _step_to_end(continuous, "continuous")

	# ── reload of SAVE-TP3 ────────────────────────────────────────────────
	# The economy half is replayed first (ECP2 stands in for this in production),
	# then the ideology payload lands on the SAME day, so the pending equip has
	# to wait exactly as long as it did in the continuous run.
	var reload_tp3: Dictionary = _new_world("reload-TP3")
	_expect("TP3: the reloaded runtime rebuilds the same committed economy day",
		_advance_economy_day(reload_tp3["ext"], 1) > 0, "day 1")
	_expect("TP3: the payload (PKEF + PKID) restores into a freshly built runtime",
		_restore(reload_tp3["ext"], tp3_payload))
	# `commands_applied` is a process counter, not persisted state, so the
	# restored branch is not asked about it -- everything it can answer about the
	# queued equip is asserted instead.
	_expect_tp3(reload_tp3, "reload-TP3", "TP3-restored", -1)
	# THE ANTI-EARLY-ADOPTION PROBE. Day 1 is run again on the reloaded runtime.
	# If PKID had dropped (or re-clamped) `effective_day`, the equip would fire on
	# this day and the front would carry the card on sample_day 1 instead of 2.
	_run_one_ideology_day(reload_tp3["ext"], 1, "reload-TP3/day1-probe")
	var probe_report: Dictionary = reload_tp3["ext"].get_ideology_report()
	var probe_layer: Dictionary = reload_tp3["ext"].get_derived_cell_layer_report()
	var probe_snapshot: Dictionary = reload_tp3["ext"].get_ideology_snapshot(
		int(reload_tp3["handle"]))
	_expect("TP3-early: the restored pending equip does NOT fire on a second day 1",
		int(probe_report.get("commands_applied", -1)) == 0,
		"commands_applied=%s" % str(probe_report.get("commands_applied", "?")))
	_expect("TP3-early: the card is still INACTIVE after the probe day",
		_active_locations(probe_snapshot) == 0,
		str(probe_snapshot.get("locations", "?")))
	_expect("TP3-early: the front is still empty after the probe day",
		int(probe_layer.get("cell_count", -1)) == 0,
		"cells=%s installed=%s" % [str(probe_layer.get("cell_count", "?")),
			str(probe_layer.get("installed", "?"))])
	_expect("TP3-early: the equip is still queued after the probe day",
		int(probe_report.get("pending_commands", -1)) == 1,
		"%s" % str(probe_report.get("pending_commands", "?")))
	var tp4_from_reload: Dictionary = _step_to_tp4(
		reload_tp3, "reload-TP3")
	var reloaded: Dictionary = _step_to_end(reload_tp3, "reload-TP3")

	# ── 11.7 comparison, time point 3 ─────────────────────────────────────
	_compare(reference, reloaded, "TP3")
	var continuous_pkid: PackedByteArray = tp4_from_continuous["pkid"]
	var reload_pkid: PackedByteArray = tp4_from_reload["pkid"]
	_expect("TP3: the TP4 PKID captured AFTER the reload is byte-identical to "
		+ "the continuous one (%d bytes)" % continuous_pkid.size(),
		continuous_pkid == reload_pkid,
		"%d vs %d bytes" % [continuous_pkid.size(), reload_pkid.size()])

	# ── reload of SAVE-TP4 ────────────────────────────────────────────────
	var reload_tp4: Dictionary = _new_world("reload-TP4")
	_expect("TP4: the reloaded runtime rebuilds the same committed economy day",
		_advance_economy_day(reload_tp4["ext"], 1) > 0, "day 1")
	_expect("TP4: the payload (PKEF + PKID) restores into a freshly built runtime",
		_restore(reload_tp4["ext"], tp4_from_continuous))
	var restored_layer: Dictionary = reload_tp4["ext"].get_derived_cell_layer_report()
	_expect("TP4: the restored runtime has NO front of its own yet "
		+ "(nothing can be adopted early)",
		int(restored_layer.get("cell_count", -1)) == 0,
		"cells=%s installed=%s" % [str(restored_layer.get("cell_count", "?")),
			str(restored_layer.get("installed", "?"))])
	var restored_snapshot: Dictionary = reload_tp4["ext"].get_ideology_snapshot(
		int(reload_tp4["handle"]))
	_expect("TP4: the restored payload already carries the ADOPTED card "
		+ "(equipped, no pending command, no in-flight transition)",
		_active_locations(restored_snapshot) > 0
			and int(reload_tp4["ext"].get_ideology_report().get(
				"pending_commands", -1)) == 0
			and int(reload_tp4["ext"].get_ideology_report().get(
				"pending_transitions", -1)) == 0,
		"locations=%s pending=%s transitions=%s" % [
			str(restored_snapshot.get("locations", "?")),
			str(reload_tp4["ext"].get_ideology_report().get("pending_commands", "?")),
			str(reload_tp4["ext"].get_ideology_report().get("pending_transitions", "?"))])
	# The reload adopts on the same day the continuous run adopted -- the
	# PROJECTION's eligibility day, one after the confirmation. The rebuild is
	# driven with the day explicitly, exactly as the save coordinator's finalize
	# step does (plan 11.4 item 4/5): rebuild the front from the restored rows.
	_open_epoch(reload_tp4, ELIGIBILITY_DAY, "reload-TP4")
	var reload_epoch_report: Dictionary = reload_tp4["ext"].get_economy_report()
	var reload_layer_at_open: Dictionary = \
		reload_tp4["ext"].get_derived_cell_layer_report()
	_expect("TP4: the reloaded runtime freezes the day-2 factors BEFORE adopting "
		+ "(epoch open, front still empty -- the same order as the continuous run)",
		bool(reload_epoch_report.get("epoch_active", false))
			and int(reload_epoch_report.get("sample_day", -1)) == ELIGIBILITY_DAY
			and int(reload_layer_at_open.get("cell_count", -1)) == 0,
		"epoch_active=%s sample_day=%s front_cells=%s" % [
			str(reload_epoch_report.get("epoch_active", "?")),
			str(reload_epoch_report.get("sample_day", "?")),
			str(reload_layer_at_open.get("cell_count", "?"))])
	# THE FINDING THIS PRINT USED TO RECORD IS CLOSED, so it is an assertion now.
	# Schema 11 writes the pair before the trailer (`ideology_runtime.cpp:6559-6561`),
	# so a restored runtime comes back WITH its eligibility gate. This payload was
	# taken on the eligibility day itself and still reports the pair it was written
	# with; the save point that actually exercises the gate is SAVE-TP4-confirmed,
	# reloaded below.
	var restored_dates: Dictionary = reload_tp4["ext"].get_ideology_report()
	print("[sv34/TP4-reload] restored basis dates confirmed=%s eligible=%s "
		% [str(restored_dates.get("derived_basis_confirmed_day", "?")),
			str(restored_dates.get("derived_basis_eligible_day", "?"))]
		+ "(persisted by PKID schema 11 -- formerly the -1/-1 gap)")
	_expect("TP4: the restored runtime holds the payload's OWN basis dates "
		+ "(confirmed %d / eligible %d, persisted since PKID schema 11)"
		% [ELIGIBILITY_DAY, PROJECTION_ELIGIBLE_DAY],
		int(restored_dates.get("derived_basis_confirmed_day", -2)) == ELIGIBILITY_DAY
			and int(restored_dates.get("derived_basis_eligible_day", -2))
				== PROJECTION_ELIGIBLE_DAY,
		"confirmed=%s eligible=%s expected=%d/%d" % [
			str(restored_dates.get("derived_basis_confirmed_day", "?")),
			str(restored_dates.get("derived_basis_eligible_day", "?")),
			ELIGIBILITY_DAY, PROJECTION_ELIGIBLE_DAY])
	_run_one_ideology_day(reload_tp4["ext"], PROJECTION_ELIGIBLE_DAY,
		"reload-TP4/day%d" % PROJECTION_ELIGIBLE_DAY)
	var reload_tp4_layer: Dictionary = reload_tp4["ext"].get_derived_cell_layer_report()
	_expect("TP4: the reloaded runtime adopts on the projection's eligibility day "
		+ "(front sample_day == %d)" % PROJECTION_ELIGIBLE_DAY,
		int(reload_tp4_layer.get("sample_day", -1)) == PROJECTION_ELIGIBLE_DAY,
		"sample_day=%s expected=%d" % [
			str(reload_tp4_layer.get("sample_day", "?")),
			PROJECTION_ELIGIBLE_DAY])
	# The SAME eligibility-day drain the continuous run performed, so the two
	# branches stay call-for-call identical and differ only in the save/reload
	# boundary.
	var reload_drained: Dictionary = reload_tp4["ext"].drain_derived_cell_layer(
		PROJECTION_ELIGIBLE_DAY)
	_expect("TP4: the reloaded runtime's eligibility-day rebuild folds to "
		+ "completion", bool(reload_drained.get("complete", false)),
		str(reload_drained))
	var reloaded_tp4: Dictionary = _step_to_end(reload_tp4, "reload-TP4")

	# ── 11.7 comparison, time point 4 ─────────────────────────────────────
	_compare(reference, reloaded_tp4, "TP4")
	_expect("TP4: the derived layer was adopted on the same day in both runs",
		int(reference["layer_sample_day"]) == int(reloaded_tp4["layer_sample_day"])
			and int(reference["layer_sample_day"]) == PROJECTION_ELIGIBLE_DAY,
		"%d vs %d (projection eligibility day %d = confirmed %d + 1)" % [
			int(reference["layer_sample_day"]),
			int(reloaded_tp4["layer_sample_day"]), PROJECTION_ELIGIBLE_DAY,
			ELIGIBILITY_DAY])
	_expect("TP4: both runs installed the front exactly once (no re-install "
		+ "at the later boundary)",
		int(reference["layer_generation"]) == int(reloaded_tp4["layer_generation"])
			and int(reference["layer_generation"]) == 1,
		"%d vs %d" % [int(reference["layer_generation"]),
			int(reloaded_tp4["layer_generation"])])
	_expect("TP4: both runs cross the next freeze boundary on the same day",
		int(reference["economy_sample_day"]) == FINAL_DAY
			and int(reloaded_tp4["economy_sample_day"]) == FINAL_DAY,
		"%d vs %d (expected %d)" % [int(reference["economy_sample_day"]),
			int(reloaded_tp4["economy_sample_day"]), FINAL_DAY])

	# ── reload of SAVE-TP4-confirmed ──────────────────────────────────────
	# THE DIRECTION THAT WAS NOT TESTABLE before PKID schema 11: a payload captured
	# while the basis is CONFIRMED but not yet ELIGIBLE. The restored runtime has to
	# come back with the pair intact and therefore still REFUSE to adopt on the
	# confirmation day, instead of adopting one day early because it forgot when the
	# projection became eligible.
	_reload_confirmed(tp4_from_continuous)

	_negative_control(reference, tp3_payload)
	_negative_basis_dates(tp4_from_continuous)
	_finish()


# ─────────────────────────────────────────────────────────────────────────
# the timeline, in three steps shared by every branch
# ─────────────────────────────────────────────────────────────────────────

## Everything up to and including SAVE-TP3. The economy half is advanced FIRST so
## that the reload branch, which can only replay the economy, reaches the same
## committed day with the same ordering.
func _step_to_tp3(world: Dictionary, batches: Array, label: String) -> void:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	for index in range(batches.size()):
		_submit(ext, batches[index], handle)
	_expect("%s: the economy reaches committed day 1" % label,
		_advance_economy_day(ext, 1) > 0, "day 1")
	# Day 0 applies GRANT + DISCOVER. The EQUIP is due on ELIGIBILITY_DAY and is
	# therefore NOT touched by either day.
	_run_one_ideology_day(ext, 0, "%s/day0" % label)
	_run_one_ideology_day(ext, 1, "%s/day1" % label)


## SAVE-TP4, in the TWO time points §9.3 splits it into: the equip day (the
## projection is confirmed but not yet eligible) and its eligibility day (the front
## is adopted while the epoch of the equip day is still open).
##
## TWO payloads come out of this: `confirmed` -- the save point of the equip day,
## taken between the settle and the publish -- and the payload returned at the top
## level, which is the eligibility-day save point every other branch uses.
##
## The epoch is opened FIRST on purpose -- that is what makes the freeze boundary
## the old, pre-adoption one.
func _step_to_tp4(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var epoch_report: Dictionary = _open_epoch(world, ELIGIBILITY_DAY, label)
	# The proof that the freeze happened BEFORE the adoption: the front the epoch
	# froze its factors from was still empty.
	var layer_before: Dictionary = ext.get_derived_cell_layer_report()
	_expect("%s: when the day %d epoch opened the front was still EMPTY "
		% [label, ELIGIBILITY_DAY] + "(the epoch froze pre-adoption factors)",
		int(layer_before.get("cell_count", -1)) == 0,
		"cells=%s installed=%s epoch_active=%s sample_day=%s" % [
			str(layer_before.get("cell_count", "?")),
			str(layer_before.get("installed", "?")),
			str(epoch_report.get("epoch_active", "?")),
			str(epoch_report.get("sample_day", "?"))])
	_run_one_ideology_day(ext, ELIGIBILITY_DAY, "%s/day%d" % [label,
		ELIGIBILITY_DAY])
	# THE SETTLE (plans 10.1 and 9.3). The equip command is applied -- and its
	# structural transition started -- inside the slice that ALSO runs the day's
	# collect step (`step_derived_rebuild`). At that instant the transition is not
	# ACKed, so an un-ACKed equip contributes NOTHING (`:2317-2318`) and that
	# collect publishes an EMPTY front. The acker in `_run_one_ideology_day` settles
	# the transaction on the following slice, and that slice's rebuild is REFUSED by
	# §9.3 (`:7090-7101`, `derived_basis_eligible_day == day + 1`).
	# `_settle_confirmation` re-enters the day to settle it and asserts the refusal;
	# `_publish_eligible_day` then runs the eligibility day, whose rebuild publishes
	# the confirmed basis.
	var settle_label := "%s/day%d/settle" % [label, ELIGIBILITY_DAY]
	var confirmed_report: Dictionary = _settle_confirmation(ext, ELIGIBILITY_DAY,
		settle_label)
	# ====== SAVE-TP4-confirmed ====== taken HERE: the projection is confirmed, its
	# eligibility day has not arrived, and the front is still the previous (empty)
	# one. Before PKID schema 11 this payload would have reloaded as -1 / -1 with no
	# gate; `_reload_confirmed` proves it now does not.
	var confirmed_payload: Dictionary = _capture(ext,
		"%s/TP4-confirmed" % label)
	_publish_eligible_day(ext, ELIGIBILITY_DAY, settle_label)
	# The state the CONTINUOUS run reaches on the eligibility day, captured before
	# anything else moves so the restored branch has something exact to be compared
	# against (same sample_day, same generation, same per-cell fingerprint).
	var eligible_state: Dictionary = _probe_state(world,
		"%s/TP4-confirmed+eligible" % label)
	var payload: Dictionary = _capture(ext, "%s/TP4" % label)
	_expect_tp4(world, label, "TP4")
	payload["confirmed"] = confirmed_payload
	payload["confirmed_report"] = confirmed_report
	payload["eligible_state"] = eligible_state
	return payload


## The settle half of TP4-confirmed: re-enter `day` so `run_daily_slices` polls
## `_pending_transitions` first (`ideology_runtime.cpp:4954-4968`), then assert that
## the §9.3 gate REFUSED to publish the confirmed projection on its confirmation day.
##
## `day` must be the day the runtime is currently on: re-entering an EARLIER day
## would leave `_last_day < day` false and silently skip that day's work
## (`:5019`). Re-entering the SAME day is legal and is exactly what settles the
## transition.
##
## Returns the ideology report at that moment, so a caller can save the payload of
## the confirmed-but-not-eligible state without re-deriving it.
func _settle_confirmation(ext: Object, day: int, label: String) -> Dictionary:
	_run_one_ideology_day(ext, day, label)
	var report: Dictionary = ext.get_ideology_report()
	_expect("%s: no structural transition is left in flight after the settle pass"
		% label, int(report.get("pending_transitions", -1)) == 0,
		"pending_transitions=%s" % str(report.get("pending_transitions", "?")))
	# ── the state §9.3 creates: CONFIRMED today, publishable tomorrow ──────
	_expect("%s: the confirmation is dated (confirmed_day == %d) and the projection "
		% [label, day] + "is only eligible from day %d" % (day + 1),
		int(report.get("derived_basis_confirmed_day", -1)) == day
			and int(report.get("derived_basis_eligible_day", -1)) == day + 1,
		"confirmed=%s eligible=%s" % [
			str(report.get("derived_basis_confirmed_day", "?")),
			str(report.get("derived_basis_eligible_day", "?"))])
	_expect("%s: the day-%d rebuild was REFUSED by the eligibility gate "
		% [label, day] + "(derived_rebuild_gated_by_eligibility > 0)",
		int(report.get("derived_rebuild_gated_by_eligibility", 0)) > 0,
		"gated=%s" % str(report.get(
			"derived_rebuild_gated_by_eligibility", "?")))
	# The front is the PREVIOUS one: nothing was published on the confirmation day.
	# The gated return clears `_derived_rebuild_day` (`:7090-7101`), so
	# `drain_derived_cell_layer(day)` has nothing to finish -- measured here, not
	# assumed.
	var at_confirm: Dictionary = ext.get_derived_cell_layer_report()
	var stuck: Dictionary = ext.drain_derived_cell_layer(day)
	print("[sv34/%s] FINDING confirmation day %d: gated=%s front installed=%s "
		% [label, day, str(report.get("derived_rebuild_gated_by_eligibility", "?")),
			str(at_confirm.get("installed", "?"))]
		+ "cells=%s | drain(day) steps=%s complete=%s"
		% [str(at_confirm.get("cell_count", "?")), str(stuck.get("steps", "?")),
			str(stuck.get("complete", "?"))])
	_expect("%s: the confirmation day publishes NOTHING (the previous front is "
		% label + "still the one in force)",
		int(at_confirm.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [str(at_confirm.get("installed", "?")),
			str(at_confirm.get("cell_count", "?"))])
	return report


## The publish half: `day + 1` is the FIRST rebuild allowed to adopt the confirmed
## basis, so this is the pass whose front carries the card.
func _publish_eligible_day(ext: Object, day: int, label: String) -> Dictionary:
	_run_one_ideology_day(ext, day + 1, "%s/eligible%d" % [label, day + 1])
	var after: Dictionary = ext.get_ideology_report()
	var drained: Dictionary = ext.drain_derived_cell_layer(day + 1)
	_expect("%s: the eligibility day's rebuild leaves no derived rebuild pending"
		% label, bool(drained.get("complete", false))
			and not bool(after.get("derived_rebuild_pending", true)),
		str(drained))
	return after


## The tail both branches run after SAVE-TP4: commit day 2, cross the day-3
## boundary (the adoption), run ideology day 3, then capture the state.
func _step_to_end(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	_expect("%s: economy day %d commits after the TP4 save point"
		% [label, ELIGIBILITY_DAY],
		_advance_economy_day(ext, ELIGIBILITY_DAY) > 0, "day 2")
	# Day 3 is the first freeze boundary that can see the card: `start_epoch(3)`
	# runs `refresh_city_modifier_factors` against a front that now carries it.
	_expect("%s: economy day %d commits (the adoption boundary)" % [label, FINAL_DAY],
		_advance_economy_day(ext, FINAL_DAY) > 0, "day 3")
	_run_one_ideology_day(ext, FINAL_DAY, "%s/day%d" % [label, FINAL_DAY])
	# Belt and braces: if a day's slices ended before the sharded rebuild folded,
	# drain it explicitly. `complete` must be true either way.
	var drained: Dictionary = ext.drain_derived_cell_layer(FINAL_DAY)
	_expect("%s: the derived rebuild has no work left after day %d"
		% [label, FINAL_DAY], bool(drained.get("complete", false)), str(drained))
	return _capture_state(world, label)


# ─────────────────────────────────────────────────────────────────────────
# the two time points, as assertions
# ─────────────────────────────────────────────────────────────────────────

## TIME POINT 3 -- "confirmed but not yet at the eligibility day".
##
## Every field asserted here is read back from the runtime; none of them is
## assumed from the fixture's own bookkeeping. `applied_expected` is -1 on a
## restored branch, where `commands_applied` is a fresh process counter.
func _expect_tp3(world: Dictionary, label: String, tag: String,
		applied_expected: int) -> void:
	var ext: Object = world["ext"]
	var report: Dictionary = ext.get_ideology_report()
	var snapshot: Dictionary = ext.get_ideology_snapshot(int(world["handle"]))
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var economy: Dictionary = ext.get_economy_report()
	# 1. The intent is CONFIRMED: admitted by submit_commands (asserted inside
	#    `_submit`) and still sitting in the durable command queue.
	_expect("%s: the equip intent is admitted and still queued "
		% tag + "(pending_commands == 1)", int(report.get("pending_commands", -1)) == 1,
		"pending=%s" % str(report.get("pending_commands", "?")))
	# 2. The eligibility day has NOT arrived.
	if applied_expected >= 0:
		# Two business days ran and the only commands ever applied are GRANT +
		# DISCOVER: the equip's own `effective_day` has not been reached.
		_expect("%s: only GRANT+DISCOVER have run, so the equip is not eligible yet"
			% tag, int(report.get("commands_applied", -1)) == applied_expected,
			"commands_applied=%s expected=%d"
				% [str(report.get("commands_applied", "?")), applied_expected])
	_expect("%s: the card is not equipped (no IDEOLOGY slot)" % tag,
		_active_locations(snapshot) == 0,
		str(snapshot.get("locations", "?")))
	# 3. Nothing has been adopted: no front at all, so no factor can be in use.
	_expect("%s: no derived front exists before the eligibility day" % tag,
		int(layer.get("cell_count", -1)) == 0,
		"cells=%s installed=%s" % [str(layer.get("cell_count", "?")),
			str(layer.get("installed", "?"))])
	# 4. Nothing is in flight. An admitted-but-not-yet-due command is the ONLY
	#    thing outstanding at this save point, which is what makes it time point 3
	#    and not time point 2 (pending structural transaction).
	_expect("%s: no structural transaction is in flight at the save point" % tag,
		int(report.get("pending_transitions", -1)) == 0,
		"%s" % str(report.get("pending_transitions", "?")))
	# 4b. No projection has been CONFIRMED at all yet, so the §9.3 basis dates do
	#     not exist. Asserted rather than left implicit: the pair of dates is how a
	#     reader tells "nothing confirmed" (-1/-1) from "confirmed but not eligible
	#     yet" (D / D+1).
	_expect("%s: no projection is confirmed yet, so both basis dates are unset" % tag,
		int(report.get("derived_basis_confirmed_day", 0)) == -1
			and int(report.get("derived_basis_eligible_day", 0)) == -1,
		"confirmed=%s eligible=%s" % [
			str(report.get("derived_basis_confirmed_day", "?")),
			str(report.get("derived_basis_eligible_day", "?"))])
	# 5. The economy half is a committed world with no open epoch, which is what
	#    the reload branch reconstructs.
	_expect("%s: the economy is at committed day 1 with no open epoch" % tag,
		int(economy.get("last_committed_day", -1)) == 1
			and not bool(economy.get("epoch_active", true)),
		"committed=%s epoch_active=%s" % [
			str(economy.get("last_committed_day", "?")),
			str(economy.get("epoch_active", "?"))])
	print("[sv34/%s] pending_commands=%s pending_transitions=%s applied=%s "
		% [tag, str(report.get("pending_commands", "?")),
			str(report.get("pending_transitions", "?")),
			str(report.get("commands_applied", "?"))]
		+ "locations=%s front_cells=%s committed_day=%s"
		% [str(snapshot.get("locations", "?")),
			str(layer.get("cell_count", "?")),
			str(economy.get("last_committed_day", "?"))])


## TIME POINT 4 -- "the eligibility day has arrived but the old epoch has not
## ended".
##
## The projection was confirmed on ELIGIBILITY_DAY, so plan §9.3 makes
## `sample_day` of the front the ELIGIBILITY day of the PROJECTION
## (`PROJECTION_ELIGIBLE_DAY = confirmed_day + 1`), while the epoch that is still
## open is the one for ELIGIBILITY_DAY -- the command's own effective day. Two
## different clocks, and the state that makes this time point interesting.
func _expect_tp4(world: Dictionary, label: String, tag: String) -> void:
	var ext: Object = world["ext"]
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var economy: Dictionary = ext.get_economy_report()
	var report: Dictionary = ext.get_ideology_report()
	var snapshot: Dictionary = ext.get_ideology_snapshot(int(world["handle"]))
	var owned: int = int(world["owned"])
	# 1. The projection's eligibility day HAS arrived: the front was built and
	#    installed FOR it. §9.3 forbids adopting a confirmed projection on its
	#    confirmation day, so `sample_day` is confirmed_day + 1 and cannot be
	#    ELIGIBILITY_DAY itself.
	_expect("%s: the derived front is installed for sample_day %d "
		% [tag, PROJECTION_ELIGIBLE_DAY]
		+ "(confirmed_day %d + 1: plan §9.3)" % ELIGIBILITY_DAY,
		int(layer.get("sample_day", -1)) == PROJECTION_ELIGIBLE_DAY,
		"sample_day=%s expected=%d" % [str(layer.get("sample_day", "?")),
			PROJECTION_ELIGIBLE_DAY])
	_expect("%s: the front carries the card's rows (2 stats x %d owned cells)"
		% [tag, owned],
		int(layer.get("cell_count", -1)) == 2 * owned
			and int(layer.get("stat_count", -1)) == 2,
		"cells=%s stats=%s expected=%d" % [str(layer.get("cell_count", "?")),
			str(layer.get("stat_count", "?")), 2 * owned])
	# 2. The OLD EPOCH has not ended: it is open, it is the epoch FOR the
	#    eligibility day, and the previous day is still the last committed one.
	_expect("%s: the epoch for day %d is still OPEN (old epoch not ended)"
		% [tag, ELIGIBILITY_DAY],
		bool(economy.get("epoch_active", false))
			and int(economy.get("sample_day", -1)) == ELIGIBILITY_DAY
			and int(economy.get("last_committed_day", -1)) == ELIGIBILITY_DAY - 1,
		"epoch_active=%s sample_day=%s last_committed=%s" % [
			str(economy.get("epoch_active", "?")),
			str(economy.get("sample_day", "?")),
			str(economy.get("last_committed_day", "?"))])
	# 3. The card is durably equipped and its transaction has SETTLED, so the
	#    payload does not depend on an in-flight transition being re-derived after
	#    the load (`verify_external_pending_transactions_pod`, ideology_runtime.cpp
	#    :6823). A pending transition is time point 2's business, not this one's.
	_expect("%s: the card is equipped and settled (no pending command or "
		% tag + "transition)", _active_locations(snapshot) > 0
			and int(report.get("pending_commands", -1)) == 0
			and int(report.get("pending_transitions", -1)) == 0,
		"locations=%s pending=%s transitions=%s" % [
			str(snapshot.get("locations", "?")),
			str(report.get("pending_commands", "?")),
			str(report.get("pending_transitions", "?"))])
	print("[sv34/%s] layer sample_day=%s cells=%s stats=%s generation=%s | "
		% [tag, str(layer.get("sample_day", "?")),
			str(layer.get("cell_count", "?")), str(layer.get("stat_count", "?")),
			str(layer.get("layer_generation", "?"))]
		+ "epoch_active=%s sample_day=%s last_committed=%s"
		% [str(economy.get("epoch_active", "?")),
			str(economy.get("sample_day", "?")),
			str(economy.get("last_committed_day", "?"))])


# ─────────────────────────────────────────────────────────────────────────
# SAVE-TP4-confirmed: confirmed today, eligible tomorrow, and RELOADED
# ─────────────────────────────────────────────────────────────────────────

## The reload of the CONFIRMATION-day save point -- the direction PKID schema 11
## made testable.
##
## Before schema 11 the pair `confirmed_day` / `eligible_from_day` was not persisted,
## so this payload came back as -1 / -1: `step_derived_rebuild`'s gate
## (`ideology_runtime.cpp:7090-7101`) saw no eligibility day at all and the restored
## runtime would have adopted the front on the CONFIRMATION day -- one business day
## early. The pair is now written before the trailer (`:6642-6647`), covered by the
## state hash (`:6482-6490`), validated as a pair (`:6857-6860`) and rolled back with
## everything else (`:6820-6821`), so the restored runtime has to reproduce the
## refusal.
##
## The branch is driven so that every step is the SAME call the continuous run made:
## economy day 1 replayed (the stand-in for ECP2), PKEF then PKID restored, the
## confirmation day RE-ENTERED (which is exactly the settle pass the continuous run
## performed) and then the eligibility day.
func _reload_confirmed(payload: Dictionary) -> void:
	var confirmed_payload: Dictionary = payload["confirmed"]
	var report: Dictionary = payload["confirmed_report"]
	var continuous: Dictionary = payload["eligible_state"]
	var confirmed_day := int(report.get("derived_basis_confirmed_day", -1))
	var eligible_day := int(report.get("derived_basis_eligible_day", -1))
	var pkid: PackedByteArray = confirmed_payload["pkid"]
	# ── the payload really carries the pair, in the writer's own slots ────
	# A round trip can only prove what the payload CONTAINS, so the two numbers are
	# read out of the bytes first and matched against the report of the runtime that
	# WROTE them. Without that, the restore assertion below would be satisfied by any
	# two values that happened to agree.
	var tail: Dictionary = _pkid_basis_dates(pkid)
	print("[sv34/TP4-confirmed] payload (%d bytes) tail: confirmed=%s eligible=%s "
		% [pkid.size(), str(tail["confirmed"]), str(tail["eligible"])]
		+ "contract=%s trailer=%s | live report: %s / %s contract=%s"
		% [str(tail["contract"]), str(tail["trailer"]),
			str(report.get("derived_basis_confirmed_day", "?")),
			str(report.get("derived_basis_eligible_day", "?")),
			str(report.get("execution_contract_hash", "?"))])
	# SCHEMA 13, and the layout that comes with it: the pair, the plan 11.5 contract
	# u64, then SAVE_END (the plan 18.2 basis block sits BEFORE the pair, so it does not
	# move either slot). The trailer bytes are the anchor the offsets are derived
	# from, so decoding "END!" here is what makes the two numbers before it the
	# date slots rather than two arbitrary 8-byte windows.
	_expect("TP4c: the payload is PKID schema %d -- the version that carries the "
		% PKID_SCHEMA + "plan 11.5 execution-contract identity",
		pkid.decode_s32(PKID_OFF_SCHEMA) == PKID_SCHEMA,
		"schema=%d expected=%d" % [pkid.decode_s32(PKID_OFF_SCHEMA), PKID_SCHEMA])
	_expect("TP4c: the PKID payload carries the basis dates in the two s64 slots "
		+ "before the contract u64 and the SAVE_END trailer (schema 13)",
		int(tail["confirmed"]) == confirmed_day
			and int(tail["eligible"]) == eligible_day
			and String(tail["trailer"]) == "END!",
		"payload=%s/%s report=%d/%d trailer=%s" % [str(tail["confirmed"]),
			str(tail["eligible"]), confirmed_day, eligible_day,
			str(tail["trailer"])])
	# THE SLOT THE OFFSETS SKIP, proven to be what it is claimed to be. Without this,
	# "the dates are 16 bytes before the trailer" would be a layout the fixture asserts
	# about its own arithmetic: the u64 between the pair and the trailer has to be the
	# writer's OWN execution-contract identity, i.e. the number its report exposes.
	_expect("TP4c: the u64 between the basis dates and the SAVE_END trailer is the "
		+ "writer's own plan 11.5 execution-contract identity (@ %d)"
		% int(_pkid_basis_offsets(pkid)["contract"]),
		int(tail["contract"]) != 0
			and int(tail["contract"]) == int(report.get("execution_contract_hash", 0)),
		"payload=%s report=%s" % [str(tail["contract"]),
			str(report.get("execution_contract_hash", "?"))])

	# ── restore into a freshly built runtime ──────────────────────────────
	var world: Dictionary = _new_world("reload-TP4c")
	var ext: Object = world["ext"]
	_expect("TP4c: the reloaded runtime rebuilds the same committed economy day",
		_advance_economy_day(ext, 1) > 0, "day 1")
	_expect("TP4c: the CONFIRMATION-day payload (PKEF + PKID) restores into a "
		+ "freshly built runtime", _restore(ext, confirmed_payload))
	var restored: Dictionary = ext.get_ideology_report()
	# ── THE NEW EVIDENCE: the pair survives, unchanged ────────────────────
	print("[sv34/TP4-confirmed] basis dates BEFORE save: confirmed=%d eligible=%d | "
		% [confirmed_day, eligible_day]
		+ "AFTER restore: confirmed=%s eligible=%s"
		% [str(restored.get("derived_basis_confirmed_day", "?")),
			str(restored.get("derived_basis_eligible_day", "?"))])
	_expect("TP4c: both basis dates SURVIVE the round trip unchanged "
		+ "(confirmed %d -> %d, eligible %d -> %d)"
		% [confirmed_day, int(restored.get("derived_basis_confirmed_day", -2)),
			eligible_day, int(restored.get("derived_basis_eligible_day", -2))],
		int(restored.get("derived_basis_confirmed_day", -2)) == confirmed_day
			and int(restored.get("derived_basis_eligible_day", -2)) == eligible_day,
		"confirmed=%s eligible=%s expected=%d/%d" % [
			str(restored.get("derived_basis_confirmed_day", "?")),
			str(restored.get("derived_basis_eligible_day", "?")),
			confirmed_day, eligible_day])
	var layer_after_load: Dictionary = ext.get_derived_cell_layer_report()
	var snapshot_after_load: Dictionary = ext.get_ideology_snapshot(int(world["handle"]))
	_expect("TP4c: the restored front is still the PREVIOUS (empty) one -- a load "
		+ "adopts nothing by itself (installed=false, cells=0)",
		int(layer_after_load.get("cell_count", -1)) == 0
			and not bool(layer_after_load.get("installed", true)),
		"installed=%s cells=%s sample_day=%s" % [
			str(layer_after_load.get("installed", "?")),
			str(layer_after_load.get("cell_count", "?")),
			str(layer_after_load.get("sample_day", "?"))])
	_expect("TP4c: the payload comes back with the card equipped and settled "
		+ "(no pending command, no in-flight transition)",
		_active_locations(snapshot_after_load) > 0
			and int(restored.get("pending_commands", -1)) == 0
			and int(restored.get("pending_transitions", -1)) == 0,
		"locations=%s pending=%s transitions=%s" % [
			str(snapshot_after_load.get("locations", "?")),
			str(restored.get("pending_commands", "?")),
			str(restored.get("pending_transitions", "?"))])

	# ── THE MISSING DIRECTION: re-enter the CONFIRMATION day ──────────────
	# This is the pass that could not be tested before schema 11. With the pair
	# persisted, `confirmed_day < eligible_day` still holds, so the gate must refuse.
	# With the old -1 / -1 reload there was NO gate and this exact call installed the
	# front one day early -- the failure mode the fix removed.
	_run_one_ideology_day(ext, confirmed_day,
		"reload-TP4c/day%d-probe" % confirmed_day)
	var probed: Dictionary = ext.get_ideology_report()
	var probed_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("TP4c: re-entering the CONFIRMATION day (day %d) on the RESTORED "
		% confirmed_day + "runtime is REFUSED by the 9.3 gate",
		int(probed.get("derived_rebuild_gated_by_eligibility", 0)) > 0,
		"gated=%s eligible=%s" % [
			str(probed.get("derived_rebuild_gated_by_eligibility", "?")),
			str(probed.get("derived_basis_eligible_day", "?"))])
	_expect("TP4c: the confirmation-day probe adopts NOTHING on the restored "
		+ "runtime (installed=false, cells=0)",
		int(probed_layer.get("cell_count", -1)) == 0
			and not bool(probed_layer.get("installed", true)),
		"installed=%s cells=%s sample_day=%s" % [
			str(probed_layer.get("installed", "?")),
			str(probed_layer.get("cell_count", "?")),
			str(probed_layer.get("sample_day", "?"))])
	_expect("TP4c: the refused pass leaves the restored dates untouched "
		+ "(still %d / %d)" % [confirmed_day, eligible_day],
		int(probed.get("derived_basis_confirmed_day", -2)) == confirmed_day
			and int(probed.get("derived_basis_eligible_day", -2)) == eligible_day,
		"confirmed=%s eligible=%s" % [
			str(probed.get("derived_basis_confirmed_day", "?")),
			str(probed.get("derived_basis_eligible_day", "?"))])

	# ── the eligibility day: the first pass allowed to adopt ──────────────
	_run_one_ideology_day(ext, eligible_day, "reload-TP4c/day%d" % eligible_day)
	var drained: Dictionary = ext.drain_derived_cell_layer(eligible_day)
	_expect("TP4c: the eligibility day's rebuild folds to completion",
		bool(drained.get("complete", false)), str(drained))
	var adopted: Dictionary = _probe_state(world, "reload-TP4c/eligible")
	print("[sv34/TP4-confirmed] restored front: sample_day=%s generation=%s cells=%s "
		% [str(adopted["layer_sample_day"]), str(adopted["layer_generation"]),
			str((adopted["layer"] as Dictionary).get("cell_count", "?"))]
		+ "fingerprint=%s | continuous: sample_day=%s generation=%s cells=%s"
		% [str(adopted["fingerprint"]), str(continuous["layer_sample_day"]),
			str(continuous["layer_generation"]),
			str((continuous["layer"] as Dictionary).get("cell_count", "?"))])
	_expect("TP4c: the restored runtime adopts on the SAME day the continuous run "
		+ "adopted (sample_day %d vs %d)"
		% [int(adopted["layer_sample_day"]), int(continuous["layer_sample_day"])],
		int(adopted["layer_sample_day"]) == int(continuous["layer_sample_day"])
			and int(adopted["layer_sample_day"]) == eligible_day,
		"restored=%d continuous=%d eligible_day=%d" % [
			int(adopted["layer_sample_day"]), int(continuous["layer_sample_day"]),
			eligible_day])
	_expect("TP4c: ... installed the same number of times (generation %d vs %d)"
		% [int(adopted["layer_generation"]), int(continuous["layer_generation"])],
		int(adopted["layer_generation"]) == int(continuous["layer_generation"])
			and int(adopted["layer_generation"]) == 1,
		"%d vs %d" % [int(adopted["layer_generation"]),
			int(continuous["layer_generation"])])
	_expect("TP4c: ... over the same cells (%s vs %s)"
		% [str((adopted["layer"] as Dictionary).get("cell_count", "?")),
			str((continuous["layer"] as Dictionary).get("cell_count", "?"))],
		int((adopted["layer"] as Dictionary).get("cell_count", -1))
			== int((continuous["layer"] as Dictionary).get("cell_count", -2)),
		"%s vs %s" % [
			str((adopted["layer"] as Dictionary).get("cell_count", "?")),
			str((continuous["layer"] as Dictionary).get("cell_count", "?"))])
	_expect("TP4c: ... and produced the SAME per-cell fingerprint",
		String(adopted["fingerprint"]) == String(continuous["fingerprint"]),
		"%s vs %s" % [str(adopted["fingerprint"]),
			str(continuous["fingerprint"])])
	# The extra confirmation-day pass must be a NO-OP beyond the refusal: the same
	# day re-entered is not a second day of accrual (`_last_day < day`, `:5019`), so
	# the restored runtime has to arrive at the eligible day with exactly the
	# understanding the continuous run had.
	_expect("TP4c: the refused confirmation-day pass did not double-accrue anything "
		+ "(same understanding as the continuous run)",
		str((adopted["snapshot"] as Dictionary).get("understanding_q16", "?"))
			== str((continuous["snapshot"] as Dictionary).get(
				"understanding_q16", "!")),
		"%s vs %s" % [
			str((adopted["snapshot"] as Dictionary).get("understanding_q16", "?")),
			str((continuous["snapshot"] as Dictionary).get(
				"understanding_q16", "!"))])


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
	# is cached; passing the ideology effects explicitly bypasses that cache.
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
## fixture satisfies (two cohorts of 20 each). The shipped predicate reads
## building data that a bootstrapped economy does not have, so a card filtered on
## it legitimately matches NOTHING. Must be replaced on the RESOURCE before
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


# ─────────────────────────────────────────────────────────────────────────
# world construction (identical for every branch)
# ─────────────────────────────────────────────────────────────────────────

func _new_world(label: String) -> Dictionary:
	var country_ir: Dictionary = _catalogs["country_ir"]
	# Every world owns its own EffectRuntime, so transaction ids restart at 1 here.
	# Carrying the acker's cursor across worlds would make a fresh runtime look
	# like it had nothing to ack, which silently leaves every equip transaction
	# PLANNED forever.
	_effect_cursor = 0
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
		"country_ids": PackedStringArray(["country.sv34"]),
		"country_names": PackedStringArray(["Eligibility Boundary"]),
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
	# leaves `_epoch_active` false -- i.e. the world starts with day 0 committed.
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

## The command lead, as three one-command batches with FIXED sequences (1..3).
## Every branch submits the same rows, so the idempotency keys -- and the high
## watermark PKID stores -- are identical on both sides of the comparison.
##
## The EQUIP carries `equip_day` as its effective day: that single field is the whole
## of time point 3's state. It is a parameter only so the NEG-5 timeline can submit
## the SAME equip one day earlier; every ordinary branch takes the default.
func _batches(dense: int, equip_day: int = ELIGIBILITY_DAY) -> Array:
	return [
		_batch(2, 0, -1, 64 * Q16_ONE, 1),            # GRANT_IDEOLOGY_POINTS
		_batch(1, 0, dense, 0, 2),                    # DISCOVER_IDEOLOGY
		_batch(5, equip_day, dense, 0, 3),            # EQUIP_IDEOLOGY (due day 2)
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
	# `accepted`/`pending` are the runtime's own words for "confirmed": the row is
	# in `_commands` and will be applied on its `effective_day`.
	_expect("ideology batch (seq %d) is admitted -- accepted=1"
		% int(batch["sequences"][0]),
		bool(result.get("ok", false)) and int(result.get("accepted", -1)) == 1,
		str(result))


# ─────────────────────────────────────────────────────────────────────────
# advancing
# ─────────────────────────────────────────────────────────────────────────

## One ideology day, driven to completion. `run_ideology_daily` is a SLICE stage:
## a single call may come back `done=false` with the day still in progress, and
## the derived rebuild only installs a front once its fold completes. Looping on
## the runtime's own `done` flag is what lets this fixture wait honestly instead
## of guessing a call count.
##
## THE FIXTURE ALSO PLAYS THE ACKER. An equip starts a structural Effect
## transaction and `poll_pending_transition` (ideology_runtime.cpp:3741-3750)
## only settles it once every transaction id answers ACKED. This fixture is
## main-thread only and has no runtime host, so nothing would ever ack and the
## card would sit `pending_transition_count == 1` forever. The peer lifecycle
## driven here is public API (`poll_effect_transactions` ->
## `preflight` -> `commit` -> `ack`), the same sequence
## `tests/effect/effect_runtime_test.gd:130-151` drives and
## `tests/ideology/ideology_b1_many_countries_test.gd:713-746` uses at scale.
## `ack_masks` is always the transaction's own `required_ack_mask`, so the
## fixture never invents an ack it was not asked for.
func _run_one_ideology_day(ext: Object, day: int, label: String) -> bool:
	var done := false
	var last := {}
	for _i in range(512):
		last = ext.run_ideology_daily(day)
		if not bool(last.get("ok", true)):
			_expect("%s: ideology day %d reports ok" % [label, day], false, str(last))
			return false
		_ack_effect_transactions(ext)
		if bool(last.get("done", false)):
			done = true
			break
	_expect("%s: ideology day %d completes" % [label, day], done, str(last))
	return done


## Drives every unfinished Effect transaction to ACKED.
##
## `ACKED` transactions are skipped: after a PKEF restore the log already contains
## the settled ones, and re-preflighting a settled transaction is not something
## the peer lifecycle allows.
func _ack_effect_transactions(ext: Object) -> Dictionary:
	var ids := PackedInt64Array()
	var masks := PackedInt32Array()
	var cursor := _effect_cursor
	for _page in range(16):
		var polled: Dictionary = ext.poll_effect_transactions(cursor, 1024)
		var page_ids: PackedInt64Array = polled.get("transaction_ids",
			PackedInt64Array())
		if page_ids.is_empty():
			break
		var page_masks: PackedInt32Array = polled.get("required_ack_masks",
			PackedInt32Array())
		var page_statuses: PackedInt32Array = polled.get("statuses",
			PackedInt32Array())
		for index in range(page_ids.size()):
			var mask := int(page_masks[index]) if index < page_masks.size() else 0
			var status := int(page_statuses[index]) \
				if index < page_statuses.size() else 0
			if mask == 0 or status == 4:   # 4 == EffectRuntime::ACKED
				continue
			ids.append(int(page_ids[index]))
			masks.append(mask)
		cursor = int(page_ids[page_ids.size() - 1])
	_effect_cursor = cursor
	if ids.is_empty():
		return {"seen": 0}
	var batch := {"transaction_ids": ids, "ack_masks": masks}
	var preflight: Dictionary = ext.preflight_effect_transactions(batch)
	var commit: Dictionary = ext.commit_effect_transactions(batch)
	var ack: Dictionary = ext.ack_effect_transactions(batch)
	_effect_acked += int(ack.get("acknowledged", 0))
	if not bool(preflight.get("ok", true)) or not bool(commit.get("ok", true)) \
			or not bool(ack.get("ok", true)):
		_effect_ack_failures += 1
		if _effect_ack_failures == 1:
			printerr("FAIL ack: effect transaction lifecycle refused: "
				+ "preflight=%s commit=%s ack=%s"
				% [str(preflight), str(commit), str(ack)])
	return {"seen": ids.size(), "acked": int(ack.get("acknowledged", 0))}


func _advance_economy_day(ext: Object, day: int, budget_ms: float = 0.0) -> int:
	for s in range(4096):
		var ctx := {"day_index": day, "tick_index": s}
		if budget_ms > 0.0:
			ctx["slice_budget_ms"] = budget_ms
		var r: Dictionary = ext.run_economy_slice(ctx)
		if bool(r.get("fatal", false)):
			_expect("economy day %d stays non-fatal" % day, false,
				str(r.get("fatal_reason", r)))
			return s
		if bool(r.get("done", false)):
			return s + 1
	_expect("economy day %d completes" % day, false, "4096 slices")
	return 0


## Opens the epoch of `day` and STOPS with it still open.
##
## `start_epoch` is atomic (`economy_runtime_epoch.cpp:816`), and the slice only
## checks its budget after it returns (`economy_runtime.cpp:15376`). Handing the
## slice the minimum budget is what parks the day between EPOCH_BEGIN and the
## first consuming range, which is the only state in which "the old epoch has not
## ended" exists at all.
func _open_epoch(world: Dictionary, day: int, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	for s in range(256):
		var r: Dictionary = ext.run_economy_slice({
			"day_index": day, "tick_index": s,
			"slice_budget_ms": EPOCH_PARK_BUDGET_MS})
		if bool(r.get("fatal", false)):
			_expect("%s: the day %d epoch open stays non-fatal" % [label, day],
				false, str(r.get("fatal_reason", r)))
			return {}
		var report: Dictionary = ext.get_economy_report()
		if bool(report.get("epoch_active", false)) \
				and int(report.get("sample_day", -1)) == day:
			return report
		if bool(r.get("done", false)):
			break
	_expect("%s: the day %d economy epoch can be observed OPEN" % [label, day],
		false, "the day committed before an open epoch was observable")
	return {}


# ─────────────────────────────────────────────────────────────────────────
# save / restore
# ─────────────────────────────────────────────────────────────────────────

## The save payload, in the two sections the production coordinator writes.
##
## PKEF is not optional here. `NativeIdeologyRuntime::restore` verifies that every
## equipped idea's external binding still exists in the Effect runtime
## (`has_external_binding_pod`, ideology_runtime.cpp:6793-6812) and rejects the
## payload with `ideology_effect_binding_missing_or_mismatched` otherwise. A
## fixture that restores PKID alone can therefore only ever reload a payload in
## which NOTHING is equipped -- which is why the binding has to be part of the
## payload, exactly as `game_save_coordinator` restores PKEF before PKID.
func _capture(ext: Object, label: String) -> Dictionary:
	var pkef: PackedByteArray = ext.capture_effect_state()
	var bytes: PackedByteArray = ext.capture_ideology_state()
	_expect("%s: PKID payload is produced" % label, not bytes.is_empty(),
		str(bytes.size()))
	_expect("%s: PKID payload carries the PKID magic" % label,
		_ascii_magic(bytes) == "PKID", "%s (%d bytes)" % [_ascii_magic(bytes),
			bytes.size()])
	_expect("%s: PKEF payload is produced" % label, not pkef.is_empty(),
		str(pkef.size()))
	return {"pkef": pkef, "pkid": bytes}


## Restores PKEF first, then PKID -- the production order (plan 11.4 lists
## PKEF before PKID in `_register_providers`).
func _restore(ext: Object, payload: Dictionary) -> bool:
	var effect_result: Dictionary = ext.restore_effect_state(payload["pkef"])
	if not bool(effect_result.get("ok", false)):
		print("[sv34/restore] pkef reason=%s"
			% String(effect_result.get("reason", "")))
		return false
	var result: Dictionary = ext.restore_ideology_state(payload["pkid"])
	if not bool(result.get("ok", false)):
		# The reason code is the whole diagnosis: truncation, catalog mismatch and
		# state-hash mismatch all report `ok=false` and nothing else.
		print("[sv34/restore] pkid reason=%s" % String(result.get("reason", "")))
		return false
	return true


# ─────────────────────────────────────────────────────────────────────────
# state capture + comparison
# ─────────────────────────────────────────────────────────────────────────

func _capture_state(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var state: Dictionary = _probe_state(world, label)
	var layer: Dictionary = state["layer"]
	var snapshot: Dictionary = state["snapshot"]
	var audit: Dictionary = state["audit"]
	var business: Dictionary = state["business"]
	var economy: Dictionary = state["economy"]
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
	_expect("%s: the layer reports the two card stats" % label,
		int(layer.get("stat_count", -1)) == 2,
		str(layer.get("stat_count", "?")))
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
	# must carry the CARD's own magnitude, read from the program interpreter
	# rather than from a hard-coded constant.
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
	_expect("%s: the economy reached the last continued day" % label,
		int(economy.get("newest_state_day", -1)) == FINAL_DAY,
		str(economy.get("newest_state_day", "?")))
	_expect("%s: the economy audit is available" % label,
		bool(audit.get("available", false)), str(audit.get("available", "?")))
	print("[sv34/%s] layer cells=%d contributions=%s stats=%s day=%s generation=%s"
		% [label, layer_cells, str(layer.get("contribution_count", "?")),
			str(layer.get("stat_count", "?")), str(layer.get("sample_day", "?")),
			str(layer.get("layer_generation", "?"))])
	print("[sv34/%s] card locations=%s levels=%s understanding=%s transitions=%s"
		% [label, str(snapshot.get("locations", "?")),
			str(snapshot.get("levels", "?")),
			str(snapshot.get("understanding_q16", "?")),
			str(snapshot.get("pending_transitions", "?"))])
	print("[sv34/%s] economy newest_state_day=%s sample_day=%s epoch_active=%s"
		% [label, str(economy.get("newest_state_day", "?")),
			str(economy.get("sample_day", "?")),
			str(economy.get("epoch_active", "?"))])
	print("[sv34/%s] business hash=%s points=%s ideas=%s instances=%d pending=%d"
		% [label, str(business.get("hash", "?")), str(business.get("points", "?")),
			str(business.get("ideas", "?")), int(state["instances"]),
			int(snapshot.get("pending_commands", -1))])
	print("[sv34/%s] audit available=%s pop_err=%s money_err=%s goods_err=%s"
		% [label, str(audit.get("available", false)),
			str(audit.get("population_error", "?")),
			str(audit.get("money_error", "?")),
			str(audit.get("goods_error", "?"))])
	print("[sv34/%s] economy state hash=%s" % [label,
		str(state["economy_hash"])])
	print("[sv34/%s] per-cell fingerprint=%s" % [label, state["fingerprint"]])
	var add_cells: PackedFloat64Array = (state["cells"][STAT_ADD] as Dictionary)["value"]
	var present: PackedByteArray = (state["cells"][STAT_ADD] as Dictionary)["present"]
	var first := PackedStringArray()
	for c in range(mini(8, CELLS)):
		first.append("%d:%s/%.8f" % [c, str(int(present[c])), add_cells[c]])
	print("[sv34/%s] first 8 cells (present/value, %s)=%s"
		% [label, STAT_ADD, ", ".join(first)])
	return state


## The raw state, with NO assertions. Shared by the comparison branches (which
## assert on it) and by the negative control (which must be free to observe a
## state that is simply wrong).
func _probe_state(world: Dictionary, label: String) -> Dictionary:
	var ext: Object = world["ext"]
	var handle: int = int(world["handle"])
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var cells := {}
	for stat in [STAT_ADD, STAT_CUT]:
		cells[stat] = _probe_all_cells(ext, stat)
	var business: Dictionary = ext.get_ideology_business_state()
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	var instances: Dictionary = ext.get_ideology_effect_instance_report(handle)
	var report: Dictionary = ext.get_ideology_report()
	var audit: Dictionary = ext.get_economy_committed_audit_report()
	var economy: Dictionary = ext.get_economy_report()
	return {
		"label": label, "cells": cells, "layer": layer,
		"business": business, "instances": int(instances.get("count", -1)),
		"layer_generation": int(layer.get("layer_generation", -1)),
		"layer_sample_day": int(layer.get("sample_day", -1)),
		"economy_sample_day": int(economy.get("sample_day", -1)),
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
		"audit": audit, "economy": economy,
		"economy_hash": int(ext.get_economy_state_hash()),
		"fingerprint": _fingerprint(cells),
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
		int(reference["economy"]["last_committed_day"])
		== int(other["economy"]["last_committed_day"]),
		"%d vs %d" % [int(reference["economy"]["last_committed_day"]),
			int(other["economy"]["last_committed_day"])])
	# The economy half is not part of PKID, so the reloaded branch had to REBUILD
	# it by replaying the same committed days. If that reconstruction were not
	# exact, every per-cell number above would be comparing two different worlds.
	_expect("%s: the replayed economy half is bit-identical (%s)"
		% [tag, str(reference["economy_hash"])],
		int(reference["economy_hash"]) == int(other["economy_hash"])
			and int(reference["economy_hash"]) != 0,
		"%d vs %d" % [int(reference["economy_hash"]),
			int(other["economy_hash"])])
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
	_expect("%s: the layer reports the same built-for day in both runs" % tag,
		int(reference["layer_sample_day"]) == int(other["layer_sample_day"]),
		"%d vs %d" % [int(reference["layer_sample_day"]),
			int(other["layer_sample_day"])])
	_expect("%s: both runs installed the layer the same number of times" % tag,
		int(reference["layer_generation"]) == int(other["layer_generation"]),
		"%d vs %d" % [int(reference["layer_generation"]),
			int(other["layer_generation"])])
	# Economy conservation (11.7 also compares it at every time point).
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


# ─────────────────────────────────────────────────────────────────────────
# negative control: prove the comparison can fail
# ─────────────────────────────────────────────────────────────────────────

## NEG-1: a WRONG-PAYLOAD reload. The oracle branch is handed the TP3 payload --
## the time point BEFORE the eligibility day -- and then runs the TP4
## continuation. Everything about that world is legitimate except that it is one
## time point too early, which is precisely the mistake a save/reload comparison
## exists to catch. The comparison is expected to reject it.
##
## NEG-2: a ONE-CELL perturbation of the reference arrays, to show the per-cell
## comparison has no tolerance rather than merely "some" resolution.
func _negative_control(reference: Dictionary, tp3_payload: Dictionary) -> void:
	# NEG-1
	var wrong: Dictionary = _new_world("negative-TP3-payload")
	_expect("NEG1: the reloaded runtime rebuilds the same committed economy day",
		_advance_economy_day(wrong["ext"], 1) > 0, "day 1")
	_expect("NEG1: the WRONG (one-time-point-earlier) payload still restores",
		_restore(wrong["ext"], tp3_payload))
	_open_epoch(wrong, ELIGIBILITY_DAY, "negative")
	# The TP4 continuation, minus the equip: the pending command from the TP3
	# payload is still waiting for its own eligibility day and the front is rebuilt
	# for day 2 from a state where the card is not equipped.
	wrong["ext"].drain_derived_cell_layer(ELIGIBILITY_DAY)
	var wrong_state: Dictionary = _probe_state(wrong, "negative")
	var breakage: Dictionary = _count_mismatches(reference, wrong_state)
	print("[sv34/negative] TP3-payload-instead-of-TP4: presence=%d add=%d value=%d "
		% [int(breakage["presence"]), int(breakage["add"]),
			int(breakage["value"])]
		+ "fingerprint_same=%s business_hash_same=%s sample_day=%d vs %d"
		% [str(breakage["fingerprint_same"]), str(breakage["hash_same"]),
			int(wrong_state["layer_sample_day"]),
			int(reference["layer_sample_day"])])
	_expect("NEG1: the per-cell comparison REJECTS a payload taken one time "
		+ "point earlier (%d mismatches)" % int(breakage["total"]),
		int(breakage["total"]) > 0, str(breakage))
	_expect("NEG1: the rejected branch is wrong for the right reason -- the card "
		+ "is not equipped there",
		_active_locations(wrong_state["snapshot"]) == 0,
		str(wrong_state["snapshot"]["locations"]))
	_expect("NEG1: the comparison would have failed %d of the %d core checks"
		% [int(breakage["core_failures"]), int(breakage["core_total"])],
		int(breakage["core_failures"]) >= 6,
		"%d of %d" % [int(breakage["core_failures"]),
			int(breakage["core_total"])])
	# NEG-2
	var perturbed: Dictionary = reference.duplicate(true)
	var cell: int = int((reference["cells"][STAT_ADD]["present"] as PackedByteArray)
		.find(1))
	var value_row: PackedFloat64Array = (perturbed["cells"][STAT_ADD] as Dictionary)[
		"value"]
	value_row[cell] = value_row[cell] + 0.0000001
	(perturbed["cells"][STAT_ADD] as Dictionary)["value"] = value_row
	var single: Dictionary = _count_mismatches(reference, perturbed)
	_expect("NEG2: a 1e-7 change on ONE cell produces exactly 1 value mismatch",
		int(single["value"]) == 1 and int(single["add"]) == 0
			and int(single["presence"]) == 0,
		"presence=%d add=%d value=%d" % [int(single["presence"]),
			int(single["add"]), int(single["value"])])
	print("[sv34/negative] one-cell perturbation: presence=%d add=%d value=%d "
		% [int(single["presence"]), int(single["add"]), int(single["value"])]
		+ "(cell %d of %d)" % [cell, CELLS])
	_expect("the fixture's own acker closed every Effect transaction it saw",
		_effect_ack_failures == 0,
		"refusals=%d acked=%d" % [_effect_ack_failures, _effect_acked])
	print("[sv34/acker] effect transactions acknowledged=%d refusals=%d"
		% [_effect_acked, _effect_ack_failures])


# ─────────────────────────────────────────────────────────────────────────
# negative control 2: are the two basis dates LOAD-BEARING?
# ─────────────────────────────────────────────────────────────────────────

## The PKID tail as the WRITER lays it out (`ideology_runtime.cpp:6642-6647`):
## `confirmed_day` (s64), `eligible_day` (s64), the plan 11.5 execution contract
## (u64), then the 4-byte SAVE_END trailer. Reading it from the END is what makes the
## pair addressable without parsing every variable-length country row in front of it.
##
## Derivation, right to left: trailer at `size - 4`; the contract u64 at
## `trailer - 8`; `eligible_day` at `contract - 8`; `confirmed_day` at
## `eligible_day - 8 = size - 4 - 8 - 16`.
func _pkid_basis_offsets(bytes: PackedByteArray) -> Dictionary:
	var trailer_off: int = bytes.size() - PKID_TRAILER_BYTES
	var contract_off: int = trailer_off - PKID_CONTRACT_BYTES
	var confirmed_off: int = contract_off - PKID_BASIS_DATES_BYTES
	return {
		"confirmed": confirmed_off,
		"eligible": confirmed_off + 8,
		"contract": contract_off,
		"trailer": trailer_off,
	}


func _pkid_basis_dates(bytes: PackedByteArray) -> Dictionary:
	var offsets: Dictionary = _pkid_basis_offsets(bytes)
	return {
		"confirmed": bytes.decode_s64(int(offsets["confirmed"])),
		"eligible": bytes.decode_s64(int(offsets["eligible"])),
		# s64, matching `get_ideology_report()`: the runtime casts the u64 identity
		# through int64 (`ideology_runtime.cpp:6180`), so both sides are signed.
		"contract": bytes.decode_s64(int(offsets["contract"])),
		"trailer": bytes.slice(int(offsets["trailer"]), bytes.size()) \
			.get_string_from_ascii(),
	}


## A COPY of `bytes` with the two basis dates replaced. The input is never touched:
## the mutants are compared against the original payload's tail further down.
##
## SCOPE: exactly the two date slots. The plan 11.5 contract u64 and the trailer are
## copied through untouched, so a mutant is never evidence about the contract -- and
## `_negative_basis_dates` asserts that byte-for-byte instead of trusting this comment.
func _with_basis_dates(bytes: PackedByteArray, confirmed: int,
		eligible: int) -> PackedByteArray:
	var out: PackedByteArray = bytes.duplicate()
	var offsets: Dictionary = _pkid_basis_offsets(out)
	out.encode_s64(int(offsets["confirmed"]), confirmed)
	out.encode_s64(int(offsets["eligible"]), eligible)
	return out


## Hands `world` a mutated PKID and asserts it is REFUSED with `expected_reason`.
## PKEF is restored first (the production order), so a refusal can never be blamed on
## a missing Effect binding rather than on the dates.
func _expect_pkid_refused(world: Dictionary, tag: String, payload: Dictionary,
		mutant: PackedByteArray, expected_reason: String) -> void:
	var ext: Object = world["ext"]
	var effect_result: Dictionary = ext.restore_effect_state(payload["pkef"])
	_expect("%s: the PKEF half restores, so only the PKID dates are on trial" % tag,
		bool(effect_result.get("ok", false)),
		String(effect_result.get("reason", "")))
	var result: Dictionary = ext.restore_ideology_state(mutant)
	var reason := String(result.get("reason", ""))
	print("[sv34/NEG-basis] %s -> ok=%s reason=%s (expected %s)"
		% [tag, str(result.get("ok", "?")), reason, expected_reason])
	_expect("%s: the mutant payload is REFUSED with %s" % [tag, expected_reason],
		not bool(result.get("ok", true)) and reason == expected_reason,
		"ok=%s reason=%s" % [str(result.get("ok", "?")), reason])


## NEG-3/4/5/6: are the two basis dates LOAD-BEARING, or decoration?
##
## Every question is answered by what the runtime DOES, never by what the header says:
##   3. An ILLEGAL pair must be refused, including `eligible == confirmed` -- the
##      removed failure mode ("adopt on the confirmation day") written as a pair --
##      and including a pair with only one side set.
##   4. A LEGAL but wrong pair (both +1) does not get in either, and the reason is
##      measured rather than assumed: the dates are part of the state hash
##      (`:6412-6413`), so a payload's dates cannot be rewritten AT ALL.
##   5. The pair DECIDES the adoption day: a GENUINE payload whose legal pair is one
##      day earlier restores and adopts one day earlier than the continuous run.
##      That is the failure mode the fix removed, demonstrated instead of asserted.
##   6. The direction is monotone: a GENUINE pair one day later adopts one day later,
##      so "one day early" can only be a pair one day earlier -- which is 5, and which
##      no forger can write, because of 4.
func _negative_basis_dates(payload: Dictionary) -> void:
	var confirmed_payload: Dictionary = payload["confirmed"]
	var report: Dictionary = payload["confirmed_report"]
	var continuous: Dictionary = payload["eligible_state"]
	var confirmed_day := int(report.get("derived_basis_confirmed_day", -1))
	var eligible_day := int(report.get("derived_basis_eligible_day", -1))
	var bytes: PackedByteArray = confirmed_payload["pkid"]
	var original: Dictionary = _pkid_basis_dates(bytes)
	_expect("NEG-basis: the payload under test is the CONFIRMED-day one (%d / %d) "
		% [confirmed_day, eligible_day]
		+ "and its tail is where the mutants below write",
		int(original["confirmed"]) == confirmed_day
			and int(original["eligible"]) == eligible_day,
		"payload=%s/%s expected=%d/%d" % [str(original["confirmed"]),
			str(original["eligible"]), confirmed_day, eligible_day])
	# THE MUTANTS MUST BE AIMED AT THE DATES. Schema 12 put the plan 11.5 contract u64
	# right where the old tail offsets pointed, so an offset that is off by those 8
	# bytes rewrites the CONTRACT: every NEG3/4 result below would then be a test of
	# `cell_program_execution_contract_mismatch` wearing the date test's name. This is
	# measured on a real mutant (the NEG4 shift) instead of argued from the offsets.
	var probe_offsets: Dictionary = _pkid_basis_offsets(bytes)
	var contract_probe: PackedByteArray = _with_basis_dates(bytes,
		confirmed_day + 1, eligible_day + 1)
	_expect("NEG-basis: the mutant writer touches ONLY the two date slots -- the "
		+ "11.5 contract u64 (@ %d) and the trailer are byte-identical"
		% int(probe_offsets["contract"]),
		contract_probe.slice(int(probe_offsets["contract"]),
			int(probe_offsets["trailer"]))
			== bytes.slice(int(probe_offsets["contract"]),
				int(probe_offsets["trailer"]))
			and int(_pkid_basis_dates(contract_probe)["contract"])
				== int(original["contract"]),
		"before=%s after=%s" % [str(original["contract"]),
			str(_pkid_basis_dates(contract_probe)["contract"])])
	# One world for every mutant: a refusal is total by contract (`restore` fails
	# before assigning, or rolls back), so each attempt lands on an untouched runtime.
	# That is itself asserted below instead of assumed.
	var world: Dictionary = _new_world("negative-basis-dates")
	var ext: Object = world["ext"]
	_expect("NEG-basis: the negative runtime replays the same committed economy day",
		_advance_economy_day(ext, 1) > 0, "day 1")

	# ── NEG-3: an ILLEGAL pair is refused by the pair validator ───────────
	# 3a is the pre-fix failure mode expressed as a pair: eligible == confirmed says
	# "adopt on the confirmation day", exactly what a runtime with no gate did.
	_expect_pkid_refused(world,
		"NEG3a: eligible == confirmed (%d/%d) -- the pre-fix 'adopt on the "
			% [confirmed_day, confirmed_day] + "confirmation day' pair",
		confirmed_payload, _with_basis_dates(bytes, confirmed_day, confirmed_day),
		"ideology_save_basis_dates_invalid")
	# 3b: a legal-looking shift of the SECOND date only.
	_expect_pkid_refused(world,
		"NEG3b: eligible = confirmed + 2 (%d/%d)"
			% [confirmed_day, confirmed_day + 2],
		confirmed_payload,
		_with_basis_dates(bytes, confirmed_day, confirmed_day + 2),
		"ideology_save_basis_dates_invalid")
	# 3c: only one side set. The gate treats `eligible < 0` as "no basis yet", so a
	# half-set pair is exactly how the gate would be silenced.
	_expect_pkid_refused(world,
		"NEG3c: confirmed set, eligible unset (%d/-1) -- the gate would be silenced"
			% confirmed_day,
		confirmed_payload, _with_basis_dates(bytes, confirmed_day, -1),
		"ideology_save_basis_dates_invalid")

	# ── NEG-4: a LEGAL but wrong pair (both +1) ───────────────────────────
	# The obvious forgery: shift both dates by one day. It passes the PAIR check
	# (eligible == confirmed + 1) and is refused one layer later, by the state hash,
	# because the pair is hashed. So the dates are not merely validated, they are
	# IMMUTABLE: there is no payload a forger can build that carries a rewritten pair
	# AND restores.
	var shifted: PackedByteArray = _with_basis_dates(bytes, confirmed_day + 1,
		eligible_day + 1)
	var shifted_tail: Dictionary = _pkid_basis_dates(shifted)
	_expect("NEG4: the +1 mutant really is a LEGAL pair (%s / %s) -- the pair "
		% [str(shifted_tail["confirmed"]), str(shifted_tail["eligible"])]
		+ "validator has nothing to object to",
		int(shifted_tail["confirmed"]) == int(shifted_tail["eligible"]) - 1,
		"%s/%s" % [str(shifted_tail["confirmed"]),
			str(shifted_tail["eligible"])])
	_expect_pkid_refused(world,
		"NEG4: the legal-but-wrong pair (%d/%d) is refused by the STATE HASH, "
			% [confirmed_day + 1, eligible_day + 1]
			+ "because the dates are hashed (immutable, not just validated)",
		confirmed_payload, shifted, "ideology_save_state_hash_mismatch")
	# Every refusal above must have been TOTAL. If any of them had half-applied, the
	# world would come back with dates, a front or a card it never earned.
	var untouched_report: Dictionary = ext.get_ideology_report()
	var untouched_layer: Dictionary = ext.get_derived_cell_layer_report()
	var untouched_snapshot: Dictionary = ext.get_ideology_snapshot(
		int(world["handle"]))
	_expect("NEG3/4: every refusal was TOTAL -- no basis dates, no front and no "
		+ "card survived any of the four mutants",
		int(untouched_report.get("derived_basis_confirmed_day", 0)) == -1
			and int(untouched_report.get("derived_basis_eligible_day", 0)) == -1
			and int(untouched_layer.get("cell_count", -1)) == 0
			and _active_locations(untouched_snapshot) == 0,
		"confirmed=%s eligible=%s cells=%s locations=%s" % [
			str(untouched_report.get("derived_basis_confirmed_day", "?")),
			str(untouched_report.get("derived_basis_eligible_day", "?")),
			str(untouched_layer.get("cell_count", "?")),
			str(untouched_snapshot.get("locations", "?"))])

	# ── NEG-5: the pair DECIDES the adoption day ──────────────────────────
	# An illegal or rewritten pair never gets in, so the only payload that can carry
	# a legal-but-earlier pair is a GENUINE one: a second timeline whose equip was
	# submitted for EARLY_EQUIP_DAY, so its transition settles on day 1 and its pair
	# is (1, 2). Restored here, it adopts on day 2 -- one day before the continuous
	# run's day 3.
	var early: Dictionary = _confirmation_world("early-confirm", EARLY_EQUIP_DAY)
	var early_report: Dictionary = early["report"]
	var early_payload: Dictionary = early["payload"]
	var early_tail: Dictionary = _pkid_basis_dates(early_payload["pkid"])
	_expect("NEG5: the early timeline's pair is (%d/%d) -- one day before the "
		% [EARLY_EQUIP_DAY, EARLY_EQUIP_DAY + 1]
		+ "fixture's own (%d/%d)" % [confirmed_day, eligible_day],
		int(early_tail["confirmed"]) == EARLY_EQUIP_DAY
			and int(early_tail["eligible"]) == EARLY_EQUIP_DAY + 1
			and int(early_report.get("derived_basis_confirmed_day", -2))
				== EARLY_EQUIP_DAY,
		"payload=%s/%s report=%s/%s" % [
			str(early_tail["confirmed"]), str(early_tail["eligible"]),
			str(early_report.get("derived_basis_confirmed_day", "?")),
			str(early_report.get("derived_basis_eligible_day", "?"))])
	_expect("NEG5: the legal-but-EARLIER payload restores (a legal pair it can "
		+ "carry, because a real runtime wrote it)",
		_restore(ext, early_payload))
	var early_restored: Dictionary = ext.get_ideology_report()
	var early_restored_layer: Dictionary = ext.get_derived_cell_layer_report()
	_expect("NEG5: the restored runtime holds the earlier pair unchanged (%d/%d)"
		% [EARLY_EQUIP_DAY, EARLY_EQUIP_DAY + 1],
		int(early_restored.get("derived_basis_confirmed_day", -2)) == EARLY_EQUIP_DAY
			and int(early_restored.get("derived_basis_eligible_day", -2))
				== EARLY_EQUIP_DAY + 1,
		"confirmed=%s eligible=%s" % [
			str(early_restored.get("derived_basis_confirmed_day", "?")),
			str(early_restored.get("derived_basis_eligible_day", "?"))])
	_expect("NEG5: ... and no front yet (a load adopts nothing)",
		int(early_restored_layer.get("cell_count", -1)) == 0,
		"installed=%s cells=%s" % [
			str(early_restored_layer.get("installed", "?")),
			str(early_restored_layer.get("cell_count", "?"))])
	_run_one_ideology_day(ext, EARLY_EQUIP_DAY + 1,
		"negative-basis-dates/day%d" % (EARLY_EQUIP_DAY + 1))
	var early_drained: Dictionary = ext.drain_derived_cell_layer(EARLY_EQUIP_DAY + 1)
	var early_adopted: Dictionary = ext.get_derived_cell_layer_report()
	print("[sv34/NEG-basis] NEG5 restored adoption: sample_day=%s generation=%s "
		% [str(early_adopted.get("sample_day", "?")),
			str(early_adopted.get("layer_generation", "?"))]
		+ "cells=%s | continuous sample_day=%s"
		% [str(early_adopted.get("cell_count", "?")),
			str(continuous["layer_sample_day"])])
	_expect("NEG5: the restored runtime adopts ONE DAY EARLIER than the continuous "
		+ "run (sample_day %s vs %d)"
		% [str(early_adopted.get("sample_day", "?")),
			int(continuous["layer_sample_day"])],
		int(early_adopted.get("sample_day", -1)) == EARLY_EQUIP_DAY + 1
			and int(early_adopted.get("sample_day", -1))
				< int(continuous["layer_sample_day"])
			and bool(early_drained.get("complete", false)),
		"%s vs %d (drained complete=%s)" % [
			str(early_adopted.get("sample_day", "?")),
			int(continuous["layer_sample_day"]),
			str(early_drained.get("complete", "?"))])
	_expect("NEG5: ... a REAL adoption, not an empty front (2 stats x %d owned cells)"
		% int(world["owned"]),
		int(early_adopted.get("cell_count", -1)) == 2 * int(world["owned"])
			and int(early_adopted.get("stat_count", -1)) == 2,
		"cells=%s stats=%s expected=%d" % [
			str(early_adopted.get("cell_count", "?")),
			str(early_adopted.get("stat_count", "?")), 2 * int(world["owned"])])
	print("[sv34/NEG-basis] the basis pair is load-bearing: an illegal pair is "
		+ "refused by the pair rule, a rewritten legal pair by the state hash, and "
		+ "a genuine one-day-earlier pair moves the adoption day by exactly one")

	# ── NEG-6: A DIRECTION CONTROL -- what does a pair one day LATER do? ───
	# "The pair decides the adoption day" immediately raises the question of WHICH WAY
	# it moves. Two measurements answer it: NEG-4 shows a rewritten +1 pair cannot be
	# loaded at all (the dates are hashed), and this paragraph shows what a GENUINE +1
	# pair does to the adoption day -- it moves it one day LATER, because the gate is
	# `day < eligible_day`. The gate is monotone, so "adopt one day early" has exactly
	# one shape: a legal pair one day EARLIER (NEG-5).
	var late: Dictionary = _confirmation_world("late-confirm", LATE_EQUIP_DAY)
	var late_payload: Dictionary = late["payload"]
	var late_tail: Dictionary = _pkid_basis_dates(late_payload["pkid"])
	_expect("NEG6: the late timeline's pair is (%d/%d) -- one day AFTER the "
		% [LATE_EQUIP_DAY, LATE_EQUIP_DAY + 1]
		+ "fixture's own (%d/%d)" % [confirmed_day, eligible_day],
		int(late_tail["confirmed"]) == LATE_EQUIP_DAY
			and int(late_tail["eligible"]) == LATE_EQUIP_DAY + 1,
		"payload=%s/%s expected=%d/%d" % [
			str(late_tail["confirmed"]), str(late_tail["eligible"]),
			LATE_EQUIP_DAY, LATE_EQUIP_DAY + 1])
	var late_world: Dictionary = _new_world("negative-basis-dates-late")
	var late_ext: Object = late_world["ext"]
	_expect("NEG6: the reloaded runtime rebuilds the same committed economy day",
		_advance_economy_day(late_ext, 1) > 0, "day 1")
	_expect("NEG6: the legal-but-LATER payload restores",
		_restore(late_ext, late_payload))
	var late_restored: Dictionary = late_ext.get_ideology_report()
	_expect("NEG6: the restored runtime holds the later pair unchanged (%d/%d)"
		% [LATE_EQUIP_DAY, LATE_EQUIP_DAY + 1],
		int(late_restored.get("derived_basis_confirmed_day", -2)) == LATE_EQUIP_DAY
			and int(late_restored.get("derived_basis_eligible_day", -2))
				== LATE_EQUIP_DAY + 1,
		"confirmed=%s eligible=%s" % [
			str(late_restored.get("derived_basis_confirmed_day", "?")),
			str(late_restored.get("derived_basis_eligible_day", "?"))])
	# Its confirmation day is day 3 and its eligibility day day 4, so day 3 on the
	# restored runtime is still refused -- the same shape as TP4-confirmed, one day
	# further along.
	_run_one_ideology_day(late_ext, LATE_EQUIP_DAY,
		"negative-basis-dates-late/day%d" % LATE_EQUIP_DAY)
	var late_probed: Dictionary = late_ext.get_derived_cell_layer_report()
	_expect("NEG6: the restored runtime refuses its OWN confirmation day (day %d)"
		% LATE_EQUIP_DAY,
		int(late_probed.get("cell_count", -1)) == 0
			and not bool(late_probed.get("installed", true)),
		"installed=%s cells=%s" % [str(late_probed.get("installed", "?")),
			str(late_probed.get("cell_count", "?"))])
	_run_one_ideology_day(late_ext, LATE_EQUIP_DAY + 1,
		"negative-basis-dates-late/day%d" % (LATE_EQUIP_DAY + 1))
	var late_drained: Dictionary = late_ext.drain_derived_cell_layer(
		LATE_EQUIP_DAY + 1)
	var late_adopted: Dictionary = late_ext.get_derived_cell_layer_report()
	print("[sv34/NEG-basis] NEG6 restored adoption: sample_day=%s cells=%s | "
		% [str(late_adopted.get("sample_day", "?")),
			str(late_adopted.get("cell_count", "?"))]
		+ "continuous sample_day=%s (the +1 pair DELAYS, it cannot advance)"
		% str(continuous["layer_sample_day"]))
	_expect("NEG6: the restored runtime adopts ONE DAY LATER than the continuous "
		+ "run (sample_day %s vs %d) -- a +1 pair delays, so it can never be the "
		% [str(late_adopted.get("sample_day", "?")),
			int(continuous["layer_sample_day"])]
		+ "'one day early' failure mode",
		int(late_adopted.get("sample_day", -1)) == LATE_EQUIP_DAY + 1
			and int(late_adopted.get("sample_day", -1))
				> int(continuous["layer_sample_day"])
			and bool(late_drained.get("complete", false)),
		"%s vs %d (drained complete=%s)" % [
			str(late_adopted.get("sample_day", "?")),
			int(continuous["layer_sample_day"]),
			str(late_drained.get("complete", "?"))])


## A second timeline whose EQUIP was submitted for `equip_day`.
##
## World, territory, card and sequences are the same bootstrap, so the payload it
## produces is a GENUINE save in which the projection really was confirmed on
## `equip_day` and is eligible on `equip_day + 1`. That is the only honest way to hand
## a restore a legal pair other than (2, 3): NEG-4 shows a rewritten pair cannot get
## in, because the dates are part of the state hash.
##
## NEG-5 uses it with EARLY_EQUIP_DAY (pair (1, 2) -> adoption one day EARLY), NEG-6
## with LATE_EQUIP_DAY (pair (3, 4) -> adoption one day LATE).
func _confirmation_world(tag: String, equip_day: int) -> Dictionary:
	var world: Dictionary = _new_world(tag)
	var ext: Object = world["ext"]
	var batches: Array = _batches(int(_catalogs["dense"]), equip_day)
	for index in range(batches.size()):
		_submit(ext, batches[index], int(world["handle"]))
	_expect("%s: the economy reaches committed day 1" % tag,
		_advance_economy_day(ext, 1) > 0, "day 1")
	# Days in order, never backwards: the equip is due on `equip_day`, so every day up
	# to and including it has to be walked.
	for day in range(equip_day + 1):
		_run_one_ideology_day(ext, day, "%s/day%d" % [tag, day])
	var report: Dictionary = _settle_confirmation(ext, equip_day,
		"%s/day%d/settle" % [tag, equip_day])
	return {
		"world": world,
		"payload": _capture(ext, "%s/TP4-confirmed" % tag),
		"report": report,
	}


## Counts the differences the real comparison is built on, WITHOUT asserting, so
## a deliberately wrong state can be measured instead of only rejected.
func _count_mismatches(reference: Dictionary, other: Dictionary) -> Dictionary:
	var presence := 0
	var add := 0
	var value := 0
	var core_failures := 0
	for stat in [STAT_ADD, STAT_CUT]:
		var a: Dictionary = reference["cells"][stat]
		var b: Dictionary = other["cells"][stat]
		var p := _diff_count(a["present"], b["present"])
		var d := _float_count(a["add"], b["add"])
		var v := _float_count(a["value"], b["value"])
		presence += p
		add += d
		value += v
		if p > 0:
			core_failures += 1
		if d > 0:
			core_failures += 1
		if v > 0:
			core_failures += 1
	var fingerprint_same := String(reference["fingerprint"]) \
		== String(other["fingerprint"])
	var hash_same := int(reference["business"]["hash"]) \
		== int(other["business"]["hash"])
	if not fingerprint_same:
		core_failures += 1
	if not hash_same:
		core_failures += 1
	if int(reference["instances"]) != int(other["instances"]):
		core_failures += 1
	if int(reference["layer_sample_day"]) != int(other["layer_sample_day"]):
		core_failures += 1
	return {
		"presence": presence, "add": add, "value": value,
		"total": presence + add + value,
		"fingerprint_same": fingerprint_same, "hash_same": hash_same,
		"core_failures": core_failures, "core_total": 10,
	}


func _diff_count(a: PackedByteArray, b: PackedByteArray) -> int:
	if a.size() != b.size():
		return maxi(a.size(), b.size())
	var count := 0
	for i in range(a.size()):
		if a[i] != b[i]:
			count += 1
	return count


func _float_count(a: PackedFloat64Array, b: PackedFloat64Array) -> int:
	if a.size() != b.size():
		return maxi(a.size(), b.size())
	var count := 0
	for i in range(a.size()):
		if a[i] != b[i]:
			count += 1
	return count


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
	print("=== ideology save eligibility boundary (11.7 time points 3 and 4): "
		+ "%d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
