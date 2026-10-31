extends SceneTree

## PKEF (Effect domain) save under EFFECT WORKER AUTHORITY must round-trip.
##
## THE MEASURED DEFECT THIS FIXTURE CLOSES
##
##   With the worker owning EFFECT (mask 0xFFF), `capture_effect_state()` produced a
##   payload that `restore_effect_state()` REFUSED with `pkef_instance_identity_invalid`
##   -- including when the payload was offered back to the very runtime that wrote it.
##   Every instance row carried `effect_applied = 0` together with
##   `applied_stack_count = 1`, and that is exactly the pair `EffectRuntime::restore`
##   rejects (the `((effect_applied == 0) != (applied_stack_count == 0))` term). So an
##   Effect-domain save taken while the worker owned EFFECT could not be loaded ANYWHERE.
##
## WHY THAT PAIR EXISTS, AND WHY IT IS NOT CORRUPTION
##
##   `effect_applied` is the managed apply/retire latch; only for MANAGED programs are it
##   and `applied_stack_count` advanced together, by `apply_acked_instance_transition`
##   (main thread) and by `RuntimeEffectPodAuthority::apply_ack` (worker). The POD's
##   UNMANAGED branch ("unmanaged programs keep their historical bookkeeping") sets
##   `applied_stack_count = stack_count` and never touches the latch, because the latch
##   does not gate anything for a one-shot program. The write-back
##   (`EffectRuntime::apply_pod_snapshot`) copies both fields verbatim -- deliberately, so
##   the facade holds what the POD holds -- so the side that WRITES PKEF persisted
##   `(0, 1)`, which the reader treated as corruption of a pair it does not actually own
##   for unmanaged rows.
##
## WHICH SIDE WAS CHANGED, AND WHY
##
##   The READER -- by giving its pair test the SCOPE the domain already gives it. The two
##   fields are advanced together only for a MANAGED definition
##   (`uses_managed_lifecycle`): `apply_acked_instance_transition` here and
##   `RuntimeEffectPodAuthority::apply_ack` on the worker both set them as a pair, and
##   only there. An unmanaged program is fire-and-forget, so the POD records the applied
##   stack count and never touches the latch, because nothing reads the latch for it. The
##   POD's OWN save format already scopes this identical test to `managed != 0`
##   (`runtime_effect_pod.cpp`, the `effect_pod_instance_truncated_or_invalid` chain);
##   PKEF was the only reader applying it to every row. So `restore()` now refuses a
##   MANAGED row whose latch and count disagree (a real inconsistency, still caught in
##   both directions and in both authorities -- the controls below) and accepts the
##   unmanaged bookkeeping pair the domain itself writes. The WRITER was NOT changed: the
##   payload records exactly the state the runtime holds, and the facade does not invent
##   a latch the POD never set.
##
## WHAT THIS FIXTURE ASSERTS
##
##   A. MAIN THREAD (deterministic, no worker): a managed program that fires and ACKs
##      carries `(1, 1)`; an unmanaged program that fires and ACKs carries `(0, 0)` in
##      the same payload -- i.e. the main thread NEVER writes the count alone. The
##      untouched payload restores (positive control). Then byte flips: BOTH directions of
##      the managed invariant must be REFUSED with `pkef_instance_identity_invalid` and
##      must leave the runtime byte-identical (atomicity); the same flip on the UNMANAGED
##      row must LOAD and the loaded state must BE that payload, because the exemption is
##      the format's rule and not a check that accepts everything. Each flip is asserted
##      to have changed exactly the one byte it was aimed at, so a control that corrupts
##      nothing cannot pass by doing nothing.
##   B. WORKER WORLD (mask 0xFFF, EFFECT owned by the worker): drive real days until the
##      worker has written back at least one ACKED instance, then capture PKEF, walk the
##      rows OUT OF THE BYTES, assert the payload really carries the unmanaged bookkeeping
##      pair the old reader refused, restore, and assert the recapture is BYTE-IDENTICAL.
##      The row table (ids, counts, latch, applied count) is compared row by row across
##      the round trip, so "it restored" is not the claim: the same state came back.
##
##   The offsets are DERIVED from the writer (`capture()`'s field order), never guessed,
##   and the walk is validated structurally: the metric count in every row must equal the
##   catalog's metric count, and the cursor after the last row must land on a plausible
##   `(candidate_cursor, candidate_count)` pair. A hard-coded distance from the end of the
##   payload would break silently the day a field is added.

const Q16_ONE := 65536

# RuntimeDomainId bits (gdext/src/native_simulation_host.h): IDEOLOGY 0x010,
# EFFECT 0x020, MODIFIER 0x040, GAMEPLAY_EFFECT 0x080, ECONOMY 0x100.
const DOMAIN_EFFECT := 0x020
const MASK_WORKER := 0xFFF

const WIDTH := 16
const HEIGHT := 12
const SEED := 20260213
const WORKER_SPEED := 4.0
const MAX_DRIVE_DAYS := 12
const POD_ACK_WAIT_MS := 4000
const MAX_SLICES_PER_DAY := 256

# ---- PKEF wire layout, derived from `EffectRuntime::capture()` ------------------
#
# header: u32 magic, i32 schema, i32 protocol, u64 catalog hash, i64 current day,
#         i64 last completed day, i64 run day, i32 run cursor, i64 next tx,
#         i64 acked tx, u64 next activation sequence, u32 instance count
const PKEF_MAGIC := 0x46454B50            # "PKEF" little endian
const PKEF_HDR_NEXT_ACTIVATION := 4 + 4 + 4 + 8 + 8 + 8 + 8 + 4 + 8 + 8   # 64
const PKEF_OFF_INSTANCE_COUNT := PKEF_HDR_NEXT_ACTIVATION + 8             # 72
const PKEF_OFF_INSTANCES := PKEF_OFF_INSTANCE_COUNT + 4                   # 76
# One instance row, field by field in the order `capture()` appends it, up to and
# including its own u32 metric count. The metric slab that follows is `metric_count`
# i64 values and then `metric_count` presence bytes, so the row stride is
# PKEF_INSTANCE_FIXED + 9 * metric_count.
const PKEF_INSTANCE_FIXED := \
	8 + 4 + 4 + 4 + 8 + 8 + 8 + 4 + 4 + 4 + 8 + 8 + 8 + 8 \
	+ 1 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 1 + 1 + 8 + 8 + 1 + 4
const PKEF_ROW_A_ID := 0
const PKEF_ROW_A_PROGRAM := 12
const PKEF_ROW_A_APPLIED_STACKS := 121
const PKEF_ROW_A_EFFECT_APPLIED := 153
const PKEF_ROW_A_METRIC_COUNT := 172

const PROGRAM_MANAGED := "test.pkef_managed_tick"
const PROGRAM_ONE_SHOT := "test.pkef_one_shot_tick"
const MANAGED_ID := 4242
const ONE_SHOT_ID := 4343

var _checks := 0
var _failures := 0
var _started_ms := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== effect save PKEF worker authority: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt is unavailable")
		return 1
	if not _gate_wire_layout():
		return 1
	if not _run_main_thread_leg():
		return 1
	await _run_worker_leg()
	return 0


# =========================================================================
# Phase 0: the wire layout is derived, and the derivation is checked
# =========================================================================
func _gate_wire_layout() -> bool:
	# Every constant above is a sum of the widths `capture()` writes, in order.
	# Re-deriving them here keeps the two definitions in one place: if a field
	# changes width, this total changes with it instead of silently pointing the
	# byte flips below at the wrong offset.
	var widths := PackedInt32Array([8, 4, 4, 4, 8, 8, 8, 4, 4, 4, 8, 8, 8, 8,
		1, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 8, 8, 8, 1, 1, 8, 8, 1, 4])
	var total := 0
	for width in widths:
		total += int(width)
	_expect("GATE: the per-row constant is the sum of the writer's field widths "
		+ "(%d fields, %d bytes)" % [widths.size(), total],
		total == PKEF_INSTANCE_FIXED and total == 176,
		"sum=%d constant=%d" % [total, PKEF_INSTANCE_FIXED])
	# The byte offsets used by the negative controls must land inside the record.
	_expect("GATE: the latch and applied-count byte offsets lie inside one row",
		PKEF_ROW_A_EFFECT_APPLIED < PKEF_INSTANCE_FIXED
			and PKEF_ROW_A_APPLIED_STACKS + 4 <= PKEF_INSTANCE_FIXED,
		"effect_applied@%d applied_stack_count@%d row=%d"
			% [PKEF_ROW_A_EFFECT_APPLIED, PKEF_ROW_A_APPLIED_STACKS,
				PKEF_INSTANCE_FIXED])
	return true


# =========================================================================
# Phase A: main thread -- the pairs the main thread really writes, and the
#          negative controls that keep the reader's check alive
# =========================================================================
func _run_main_thread_leg() -> bool:
	var ext = ClassDB.instantiate("DCWorldExt")
	if not _expect("A: a DCWorldExt can be instantiated", ext != null):
		return false
	var catalog := _build_catalog()
	var configured: Dictionary = ext.configure_effects(catalog.compile_native_catalog())
	if not _expect("A: the two-program catalog configures",
			bool(configured.get("ok", false)), str(configured)):
		return false
	var submitted: Dictionary = ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([MANAGED_ID, ONE_SHOT_ID]),
		"program_keys": PackedStringArray([PROGRAM_MANAGED, PROGRAM_ONE_SHOT]),
		"generations": PackedInt32Array([1, 1]),
		"target_handles": PackedInt64Array([9001, 9002]),
		"target_generations": PackedInt32Array([7, 8]),
		"next_due_days": PackedInt64Array([0, 0]),
	})
	if not _expect("A: both instances are accepted",
			bool(submitted.get("ok", false))
				and int(submitted.get("accepted", 0)) == 2, str(submitted)):
		return false
	_expect("A: a snapshot of the frozen metric is published",
		bool(ext.submit_effect_snapshots({
			"instance_ids": PackedInt64Array([MANAGED_ID, ONE_SHOT_ID]),
			"revisions": PackedInt64Array([1, 1]),
			"metric_offsets": PackedInt32Array([0, 1, 2]),
			"metric_ids": PackedInt32Array([0, 0]),
			"metric_values_q16": PackedInt64Array([5 * Q16_ONE, 5 * Q16_ONE]),
		}).get("ok", false)))
	# One evaluation, then the production preflight -> commit -> ACK sequence.
	# The managed program's ACK is what writes (1, 1); the one-shot program has
	# no transition at all, which is why the main thread leaves it (0, 0).
	# The slice budget is 4 and each program charges 6, so the day needs at least
	# two slices -- the same shape `effect_runtime_test` pins.
	var evaluated := false
	for _slice in range(16):
		var slice: Dictionary = ext.run_effect_daily(0)
		evaluated = evaluated or bool(slice.get("ok", false))
		if not bool(slice.get("ok", true)):
			break
		if bool(slice.get("done", false)):
			break
	_expect("A: the day evaluates to completion", evaluated)
	var polled: Dictionary = ext.poll_effect_transactions(0, 8)
	var tx_ids: PackedInt64Array = polled.get("transaction_ids", PackedInt64Array())
	var masks: PackedInt32Array = polled.get("required_ack_masks", PackedInt32Array())
	if not _expect("A: both programs planned a transaction (managed AND one-shot)",
			tx_ids.size() == 2 and masks.size() == 2,
			"count=%d ids=%s" % [tx_ids.size(), str(tx_ids)]):
		return false
	for step in ["preflight", "commit", "ack"]:
		var args := {"transaction_ids": tx_ids, "ack_masks": masks}
		var result: Dictionary = {}
		match step:
			"preflight":
				result = ext.preflight_effect_transactions(args)
			"commit":
				result = ext.commit_effect_transactions(args)
			_:
				result = ext.ack_effect_transactions(args)
		if not _expect("A: %s succeeds" % step, bool(result.get("ok", false)),
				str(result)):
			return false
	var managed_explain: Dictionary = ext.explain_effect(MANAGED_ID)
	var one_shot_explain: Dictionary = ext.explain_effect(ONE_SHOT_ID)
	_expect("A: the MANAGED instance is ACKed as applied (main-thread transition)",
		bool(managed_explain.get("ok", false))
			and bool(managed_explain.get("effect_applied", false))
			and int(managed_explain.get("applied_stack_count", -1)) == 1,
		str(managed_explain))
	_expect("A: the ONE-SHOT instance is NOT given the latch, and the main thread "
		+ "leaves its applied count at 0 -- the main thread never writes the count "
		+ "alone, so `(0, N)` can only come from the worker's bookkeeping",
		bool(one_shot_explain.get("ok", false))
			and not bool(one_shot_explain.get("effect_applied", true))
			and int(one_shot_explain.get("applied_stack_count", -1)) == 0,
		str(one_shot_explain))

	var before: PackedByteArray = ext.capture_effect_state()
	var walk := _walk_pkef(before)
	if not _expect("A: the captured payload walks as a PKEF with exactly its two rows",
			bool(walk.get("ok", false)) and int(walk.get("count", -1)) == 2
				and _magic_of(before) == PKEF_MAGIC, str(walk)):
		return false
	_expect("A: the walk is validated structurally -- every row's metric count is the "
		+ "catalog's metric count and the cursor lands on a plausible candidate block",
		bool(walk.get("metric_counts_uniform", false))
			and int(walk.get("metric_count", -1)) == 1
			and int(walk.get("candidate_cursor", -1)) >= 0
			and int(walk.get("candidate_count", -1)) == 2,
		str(walk))
	var rows: Array = walk.get("rows", [])
	var managed_row := _row_for_id(rows, MANAGED_ID)
	var one_shot_row := _row_for_id(rows, ONE_SHOT_ID)
	_expect("A: the managed row is written as (effect_applied=1, applied=1)",
		not managed_row.is_empty()
			and int(managed_row["effect_applied"]) == 1
			and int(managed_row["applied_stack_count"]) == 1,
		str(managed_row))
	_expect("A: the one-shot row is written as (effect_applied=0, applied=0)",
		not one_shot_row.is_empty()
			and int(one_shot_row["effect_applied"]) == 0
			and int(one_shot_row["applied_stack_count"]) == 0,
		str(one_shot_row))
	_expect("A: no row in a MAIN-THREAD payload violates the pair", 
		int(walk.get("pair_violations", -1)) == 0, str(walk.get("first_violation", "")))
	# The C++ side's own gates, in the same binary: `pod_snapshot_persistence_self_test`
	# performs a full pod-snapshot -> capture -> restore -> capture round trip on a
	# NON-MANAGED program, and `pod_state_parity_self_test` pins both authorities'
	# state semantics -- so the scoped pair rule below is exercised by the runtime's
	# own gate as well as by this fixture.
	_expect("A[SELF-TEST]: the Effect POD's own persistence and state-parity self-tests "
		+ "still pass",
		bool(ext.runtime_effect_pod_self_test()))

	# Positive control: the untouched payload restores.
	var clean: Dictionary = ext.restore_effect_state(before)
	_expect("A[POSITIVE]: the untouched main-thread payload restores",
		bool(clean.get("ok", false)), str(clean))
	_expect("A[POSITIVE]: and the recapture is byte-identical",
		ext.capture_effect_state() == before, "recapture differs")

	# ---- The MANAGED invariant, in both directions, on a MAIN-THREAD payload ----
	# This is what `pkef_instance_identity_invalid` still has to catch: a managed row
	# whose latch and stack count disagree, because both writers move them together.
	_run_pair_flip(ext, before, managed_row, PKEF_ROW_A_EFFECT_APPLIED, 1, 0,
		"NC1 managed latch 1->0")
	_run_pair_flip(ext, before, managed_row, PKEF_ROW_A_APPLIED_STACKS, 1, 0,
		"NC2 managed applied 1->0")
	# ---- The EXEMPTION, stated as an assertion rather than left implicit ------
	# An UNMANAGED row's count is bookkeeping (the POD sets it, the main thread never
	# does), so a disagreement there is not an inconsistency this format refuses --
	# the POD's own save format scopes the same test to managed rows. The flip must
	# therefore LOAD, and loading it must leave exactly the payload's state behind,
	# proving the exemption is the format's rule and not a dead check for every row.
	_run_unmanaged_exemption(ext, before, one_shot_row)
	return true


## One byte flip that must produce an illegal MANAGED pair, be refused by name, and leave
## the runtime untouched. The guard proves the flip changed the byte it aimed at, so a
## control that corrupts nothing cannot pass by doing nothing.
func _run_pair_flip(ext: Object, clean: PackedByteArray, row: Dictionary,
		field_offset: int, expect_from: int, expect_to: int, label: String) -> void:
	var target := _flip_guard(clean, row, field_offset, expect_from, expect_to, label)
	if target < 0:
		return
	var corrupted := clean.duplicate()
	corrupted.encode_u8(target, expect_to)
	var result: Dictionary = ext.restore_effect_state(corrupted)
	_expect("%s: the flipped pair is REFUSED with `pkef_instance_identity_invalid`"
		% label,
		not bool(result.get("ok", true))
			and String(result.get("reason", "")) == "pkef_instance_identity_invalid",
		str(result))
	_expect("%s: the refusal is atomic -- the runtime is byte-identical afterwards"
		% label, ext.capture_effect_state() == clean,
		"the refused payload changed the live state")


## The same flip on an UNMANAGED row, which is a legal pair for the format: the payload
## must load, and the live state must then BE the payload's (which is what "accepted"
## means). The pristine payload is restored afterwards so the runtime is left clean.
func _run_unmanaged_exemption(ext: Object, clean: PackedByteArray,
		row: Dictionary) -> void:
	var label := "NC3 unmanaged latch 0->1"
	var target := _flip_guard(clean, row, PKEF_ROW_A_EFFECT_APPLIED, 0, 1, label)
	if target < 0:
		return
	var corrupted := clean.duplicate()
	corrupted.encode_u8(target, 1)
	var result: Dictionary = ext.restore_effect_state(corrupted)
	_expect("%s: the UNMANAGED disagreement is ACCEPTED -- its count is bookkeeping, "
		% label + "not a lifecycle claim, and the POD's own save scopes the test to "
		+ "managed rows", bool(result.get("ok", false)), str(result))
	_expect("%s: and the loaded state IS that payload, so the exemption is real and "
		% label + "not a no-op", ext.capture_effect_state() == corrupted,
		"the accepted payload did not become the live state")
	var restored_clean: Dictionary = ext.restore_effect_state(clean)
	_expect("%s: the pristine payload still loads afterwards (the exemption did not "
		% label + "damage anything)", bool(restored_clean.get("ok", false))
			and ext.capture_effect_state() == clean, str(restored_clean))


## Shared guard: the row and byte exist, hold the expected value, and the flip changes
## exactly that one byte. Returns the byte offset, or -1 when the guard failed.
func _flip_guard(clean: PackedByteArray, row: Dictionary, field_offset: int,
		expect_from: int, expect_to: int, label: String) -> int:
	if not _expect("%s: the row to corrupt exists in the walked payload" % label,
			not row.is_empty() and int(row.get("offset", -1)) >= PKEF_OFF_INSTANCES,
			str(row)):
		return -1
	var target := int(row["offset"]) + field_offset
	if not _expect("%s: the targeted byte is present and holds the expected value"
			% label, target < clean.size()
				and int(clean.decode_u8(target)) == expect_from,
			"target=%d size=%d" % [target, clean.size()]):
		return -1
	var corrupted := clean.duplicate()
	corrupted.encode_u8(target, expect_to)
	var differing := 0
	for index in range(clean.size()):
		if clean[index] != corrupted[index]:
			differing += 1
	_expect("%s: the corruption changed exactly one byte (the control is real)"
		% label, differing == 1 and corrupted.size() == clean.size(),
		"differing=%d" % differing)
	return target

func _build_catalog() -> Resource:
	var catalog := EffectCatalog.new()
	catalog.metric_keys = PackedStringArray(["workshop_count"])
	catalog.max_work_per_slice = 4
	# `lifecycle = 1` is what makes a definition MANAGED
	# (`uses_managed_lifecycle`: lifecycle != 0 || managed_declared). It is
	# deliberately NOT `managed = true`: that flag also declares family
	# ownership, which would add a target-adapter contract this fixture does not
	# need. The one-shot program is the same program with `lifecycle = 0`.
	var managed := _definition(PROGRAM_MANAGED, 1)
	var one_shot := _definition(PROGRAM_ONE_SHOT, 0)
	catalog.definitions = [managed, one_shot]
	return catalog


func _definition(key: String, lifecycle: int) -> Resource:
	var definition := EffectDefinition.new()
	definition.key = StringName(key)
	definition.cadence_days = 1
	definition.max_work = 6
	definition.lifecycle = lifecycle
	definition.duration_days = 10 if lifecycle != 0 else -1
	var condition := EffectCondition.new()
	condition.op = 2 # METRIC_GTE
	condition.arg0 = 0
	condition.value_q16 = 3 * Q16_ONE
	definition.conditions = [condition]
	var read := EffectInstruction.new()
	read.op = 2 # READ_METRIC
	read.arg0 = 0
	var divisor := EffectInstruction.new()
	divisor.op = 1 # CONST
	divisor.value_q16 = 2 * Q16_ONE
	var divide := EffectInstruction.new()
	divide.op = 7 # DIV_FLOOR
	var emit := EffectInstruction.new()
	emit.op = 11 # EMIT_COMMAND
	emit.arg0 = 0
	definition.instructions = [read, divisor, divide, emit]
	var command := EffectCommand.new()
	command.action = 1
	command.domain = 3
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.command_key = StringName("test.pkef.modifier")
	command.definition_key = StringName("test.pkef.modifier.definition")
	definition.commands = [command]
	return definition


# =========================================================================
# Phase B: the worker world -- capture under EFFECT worker authority, restore
# =========================================================================
func _run_worker_leg() -> void:
	print("[W] building one worker world with mask 0x%03X (the worker owns EFFECT)"
		% MASK_WORKER)
	var w := await _build_world("W-pkef")
	if not _expect("W[1]: the worker world builds", not w.is_empty()):
		return
	var ext: Object = w["ext"]
	var days := 0
	var payload: PackedByteArray = PackedByteArray()
	var walk := {}
	var rows: Array = []
	var applied_rows := 0
	while days < MAX_DRIVE_DAYS:
		payload = ext.capture_effect_state()
		walk = _walk_pkef(payload)
		rows = walk.get("rows", [])
		applied_rows = _count_applied(rows)
		if int(walk.get("count", 0)) > 0 and applied_rows > 0:
			break
		_drive_day(w)
		days += 1
		_settle_worker(ext, POD_ACK_WAIT_MS)
	var report: Dictionary = ext.get_runtime_thread_report()
	var mask := int(report.get("authoritative_domain_mask", -1))
	print("[W] after %d driven days: mask=0x%03X state=%s fault='%s' rows=%d applied=%d "
		% [days, mask, String(report.get("simulation_host_state", "?")),
			String(report.get("fault_code", "")), int(walk.get("count", 0)),
			applied_rows]
		+ "instances=%d pod_acks=%d pod_tx=%d pod_ready=%s"
		% [int(ext.get_effect_report().get("instances", -1)),
			int(report.get("effect_pod_ack_count", -1)),
			int(report.get("effect_pod_transaction_count", -1)),
			str(report.get("effect_pod_ready", "?"))])
	_expect("W[2]: the worker really owns EFFECT (mask 0x%03X, deferred, read after "
		% MASK_WORKER + "days)", mask == MASK_WORKER
			and (mask & DOMAIN_EFFECT) != 0,
		"mask=0x%03X blocker='%s'" % [mask, String(report.get(
			"simulation_worker_blocker", ""))])
	var fault := String(report.get("fault_code", ""))
	_expect("W[2]: the worker did not fault during the leg", fault.is_empty(),
		"fault='%s'" % fault)
	_expect("W[3]: the payload has instance rows and at least one of them was ACKed "
		+ "by the worker, so the round trip below is not a comparison of zeros",
		int(walk.get("count", 0)) > 0 and applied_rows > 0,
		"rows=%d applied=%d days=%d fault='%s'"
			% [int(walk.get("count", 0)), applied_rows, days, fault])
	# The defect, stated as an assertion: the pair that the writer used to persist.
	# The bytes the payload carries for a fired one-shot row ARE the pair the old reader
	# refused -- `(effect_applied=0, applied_stack_count>0)`. Asserting its presence is
	# what makes the round trip below a test of the defect instead of a test of zeros.
	_expect("W[4]: the payload carries the domain's UNMANAGED bookkeeping pair "
		+ "(effect_applied=0 with applied_stack_count>0) -- the exact shape that used "
		+ "to be refused, so the round trip below is about the defect",
		_unmanaged_bookkeeping_rows(rows) > 0,
		"rows=%s" % str(rows))
	_expect("W[4]: and no row claims the latch WITHOUT a stack count (a latch with "
		+ "nothing applied is the reverse inconsistency and stays refused for every "
		+ "program)",
		_latch_without_count(rows) == 0,
		"rows=%s" % str(rows))
	print("[W][ROWS] %d rows, %d ACKed, unmanaged-bookkeeping rows=%d"
		% [int(walk.get("count", 0)), applied_rows,
			_unmanaged_bookkeeping_rows(rows)])
	for row_value in rows:
		var row: Dictionary = row_value
		var explain: Dictionary = ext.explain_effect(int(row["id"]))
		print(("[W][ROW] id=%d program=%d key=%s lifecycle=%d stack=%d/%d "
			+ "applied=%d effect_applied=%d latched=%d")
			% [int(row["id"]), int(row["program_id"]),
				String(explain.get("program_key", "?")),
				int(explain.get("lifecycle", -1)), int(row["stack_count"]),
				int(row["max_stacks"]), int(row["applied_stack_count"]),
				int(row["effect_applied"]), int(row["latched"])])
	# The round trip. The payload is offered BACK TO THE RUNTIME THAT WROTE IT,
	# which is the honest form of the claim: a save the writer cannot accept is
	# not a save.
	var restored: Dictionary = ext.restore_effect_state(payload)
	_expect("W[5]: the worker-authored PKEF is accepted by the runtime that wrote it",
		bool(restored.get("ok", false)), str(restored))
	if not bool(restored.get("ok", false)):
		return
	var recaptured: PackedByteArray = ext.capture_effect_state()
	_expect("W[6]: the recapture is BYTE-IDENTICAL to the captured payload",
		recaptured == payload,
		"captured=%d recaptured=%d" % [payload.size(), recaptured.size()])
	var after := _walk_pkef(recaptured)
	_expect("W[6]: the instance table survives the round trip row for row (count, "
		+ "stack counts, effect_applied, applied_stack_count, metrics length)",
		_rows_identical(rows, after.get("rows", []))
			and int(after.get("count", -1)) == int(walk.get("count", -1)),
		"before=%s after=%s" % [str(rows), str(after.get("rows", []))])
	_expect("W[6]: the restored report agrees with the captured one (instances, "
		+ "metrics, catalog identity, schema)",
		int(ext.get_effect_report().get("instances", -1))
			== int(walk.get("count", -1))
			and int(payload.decode_s32(4)) == int(recaptured.decode_s32(4)),
		"%s" % str(ext.get_effect_report()))
	ext.request_runtime_stop()
	var host: Object = w["host"]
	if host != null and is_instance_valid(host):
		host.queue_free()
	var clock: Object = w["clock"]
	if clock != null and is_instance_valid(clock):
		clock.queue_free()


# =========================================================================
# PKEF walking
# =========================================================================
func _walk_pkef(bytes: PackedByteArray) -> Dictionary:
	var out := {"ok": false, "error": "", "count": 0, "next_activation": 0,
		"rows": [], "after_instances": -1, "candidate_cursor": -1,
		"candidate_count": -1, "metric_count": -1, "metric_counts_uniform": false,
		"pair_violations": 0, "first_violation": ""}
	if bytes.size() < PKEF_OFF_INSTANCES:
		out["error"] = "payload shorter than the instance header"
		return out
	var count := int(bytes.decode_u32(PKEF_OFF_INSTANCE_COUNT))
	out["count"] = count
	out["next_activation"] = int(bytes.decode_u64(PKEF_HDR_NEXT_ACTIVATION))
	var cursor := PKEF_OFF_INSTANCES
	var rows: Array = out["rows"]
	var metric_count_seen := -1
	var uniform := true
	for index in range(count):
		if cursor + PKEF_INSTANCE_FIXED > bytes.size():
			out["error"] = "instance row %d truncated at %d" % [index, cursor]
			return out
		var base := cursor
		var metric_count := int(bytes.decode_u32(base + PKEF_ROW_A_METRIC_COUNT))
		if metric_count < 0 or metric_count > 4096:
			out["error"] = "instance row %d has an implausible metric count %d" \
				% [index, metric_count]
			return out
		if metric_count_seen < 0:
			metric_count_seen = metric_count
		elif metric_count != metric_count_seen:
			uniform = false
		var row := {
			"index": index, "offset": base,
			"id": int(bytes.decode_s64(base + PKEF_ROW_A_ID)),
			"program_id": int(bytes.decode_s32(base + PKEF_ROW_A_PROGRAM)),
			"metric_count": metric_count,
			"stack_count": int(bytes.decode_s32(base + 117)),
			"max_stacks": int(bytes.decode_s32(base + 113)),
			"applied_stack_count": int(bytes.decode_s32(base + PKEF_ROW_A_APPLIED_STACKS)),
			"effect_applied": int(bytes.decode_u8(base + PKEF_ROW_A_EFFECT_APPLIED)),
			"latched": int(bytes.decode_u8(base + 171)),
		}
		if (int(row["effect_applied"]) == 0) != (int(row["applied_stack_count"]) == 0):
			out["pair_violations"] = int(out["pair_violations"]) + 1
			if String(out["first_violation"]).is_empty():
				out["first_violation"] = \
					"instance %d: effect_applied %d vs applied_stack_count %d" \
					% [int(row["id"]), int(row["effect_applied"]),
						int(row["applied_stack_count"])]
		rows.append(row)
		cursor = base + PKEF_INSTANCE_FIXED + metric_count * 9
	out["metric_count"] = metric_count_seen
	out["metric_counts_uniform"] = uniform
	out["after_instances"] = cursor
	# The block that follows the instance rows is (i32 candidate_cursor,
	# u32 candidate_count). Reading it is the structural proof that the stride
	# above landed where the writer meant it to.
	if cursor + 8 <= bytes.size():
		out["candidate_cursor"] = int(bytes.decode_s32(cursor))
		out["candidate_count"] = int(bytes.decode_u32(cursor + 4))
	out["ok"] = String(out["error"]).is_empty()
	return out


func _row_for_id(rows: Array, instance_id: int) -> Dictionary:
	for row_value in rows:
		var row: Dictionary = row_value
		if int(row.get("id", 0)) == instance_id:
			return row
	return {}


func _count_applied(rows: Array) -> int:
	var count := 0
	for row_value in rows:
		var row: Dictionary = row_value
		if int(row.get("applied_stack_count", 0)) > 0:
			count += 1
	return count


## Rows carrying `(effect_applied=0, applied_stack_count>0)`: the domain's own shape for
## an unmanaged program that fired (the POD records the count, the latch is untouched).
func _unmanaged_bookkeeping_rows(rows: Array) -> int:
	var count := 0
	for row_value in rows:
		var row: Dictionary = row_value
		if int(row.get("effect_applied", 0)) == 0 \
				and int(row.get("applied_stack_count", 0)) > 0:
			count += 1
	return count


## Rows claiming `(effect_applied=1, applied_stack_count=0)`: a latch over nothing, which
## no writer produces and every reader must refuse.
func _latch_without_count(rows: Array) -> int:
	var count := 0
	for row_value in rows:
		var row: Dictionary = row_value
		if int(row.get("effect_applied", 0)) != 0 \
				and int(row.get("applied_stack_count", 0)) == 0:
			count += 1
	return count


## Row-by-row comparison of everything a save carries about an instance. Metrics are
## covered by the byte-identical check; this is the field table.
func _rows_identical(before: Array, after: Array) -> bool:
	if before.size() != after.size():
		return false
	for index in range(before.size()):
		var a: Dictionary = before[index]
		var b: Dictionary = after[index]
		for key in ["id", "program_id", "metric_count", "stack_count", "max_stacks",
				"applied_stack_count", "effect_applied", "latched"]:
			if int(a.get(key, -999)) != int(b.get(key, -998)):
				return false
	return true


func _magic_of(bytes: PackedByteArray) -> int:
	return int(bytes.decode_u32(0)) if bytes.size() >= 4 else 0


# =========================================================================
# the worker world
# =========================================================================
func _build_world(name: String) -> Dictionary:
	print("[BUILD/%s] generating %dx%d seed=%d mask=0x%03X"
		% [name, WIDTH, HEIGHT, SEED, MASK_WORKER])
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_shadow_on_generate = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = MASK_WORKER
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W %s" % name
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _expect("BUILD/%s: the session configures" % name,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _expect("BUILD/%s: production world generation succeeded" % name,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _expect("BUILD/%s: the production DCWorldExt is bound" % name, ext != null):
		return {}
	ext.set_runtime_ideology_parity_enabled(false)
	ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {"name": name, "host": host, "clock": clock, "ext": ext, "tick": 0}
	print("[BUILD/%s] ready in %d ms" % [name, Time.get_ticks_msec() - _started_ms])
	return w


func _drive_day(w: Dictionary) -> void:
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	var fault := String(ext.get_runtime_thread_report().get("fault_code", ""))
	if not fault.is_empty():
		return
	w["tick"] = int(w["tick"]) + 1
	var day := int(w["tick"])
	clock.current_day = float(day)
	_service_peers(ext)
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < 400:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	for _slice in range(MAX_SLICES_PER_DAY):
		var ideology: Dictionary = ext.run_ideology_daily(day)
		if not bool(ideology.get("ok", true)):
			break
		if bool(ideology.get("suppressed", false)):
			break
		if bool(ideology.get("done", false)):
			break
	for _slice in range(16):
		var effect_slice: Dictionary = ext.run_effect_daily(day)
		if not bool(effect_slice.get("ok", true)):
			break
		if bool(effect_slice.get("done", true)):
			break
	ext.dispatch_effect_native_modifier()
	ext.run_modifier_daily(day)
	ext.ack_effect_native_modifier()


func _service_peers(ext: Object, passes: int = 6) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(96, true)


## The ACK the pair depends on is produced by the WORKER, asynchronously: a day loop that
## never waits races it and keeps measuring `(0, 0)` -- measured twice, once with 12
## driven days and no waiting, where the row stayed unapplied. So give the worker a
## bounded settle window after every day and break as soon as the state is OBSERVABLE in
## the payload (not on a guessed counter): the wait is on the property the assertions are
## about, so it can only ever shorten the run, never weaken it.
func _settle_worker(ext: Object, timeout_ms: int) -> int:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var applied := 0
	while Time.get_ticks_msec() < deadline:
		applied = _count_applied(
			_walk_pkef(ext.capture_effect_state()).get("rows", []))
		if applied > 0:
			break
		var report: Dictionary = ext.get_runtime_thread_report()
		if String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
			break
		_service_peers(ext, 1)
		OS.delay_msec(15)
	return applied


func _has_hard_barrier(clock: Object) -> bool:
	return bool(clock.has_hard_barrier()) if clock.has_method("has_hard_barrier") else false


# =========================================================================
# assertions
# =========================================================================
func _expect(label: String, condition: bool, detail: String = "") -> bool:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return true
	_failures += 1
	print("[FAIL] %s :: %s" % [label, detail])
	return false


func _fail(label: String) -> void:
	_checks += 1
	_failures += 1
	print("[FAIL] " + label)
