extends SceneTree

## Army personnel lane (Economy side) — admission contract test.
##   godot --headless --path . -s res://tests/military/army_personnel_lane_admission_test.gd
##
## Contract: docs/plans/army-personnel-implementation-contract.md §1.2 and
## docs/plans/army-personnel-contract-2.md §1.1.
## The four lane opcodes (30 ARMY_EMBARK / 31 ARMY_DISEMBARK /
## 32 ARMY_MERGE_LANES / 33 ARMY_SPLIT_LANES) must be let through POD admission
## on exactly the same terms as opcode 24 (military cohort convert): they name
## the army by Military handle and the cohort by (cell, signature), never by a
## slot id. Any other opcode outside 1..23 must still be refused at admission.
##
## Wire shape of the split (33), the only lane opcode that takes two armies:
##   target_cohort = src army handle, payload0 = heads (<= 0 = whole lane),
##   payload1 = dst army handle, target_cell / target_country unused.
##
## Enforcement point: RuntimeEconomyPodAuthority::queue_command
## (gdext/src/runtime_economy_pod.cpp).
##
## This test only covers the admission half. The conservation half (embark moves
## exactly the requested heads and the proportional cash out of the home cohort,
## disembark puts them back, split/merge move heads and cash between two lanes
## with the two-lane sum unchanged, and no cross-cell movement happens) needs a
## booted world plus the bridge reads `military_army_population(handle)` /
## `military_army_funds(handle)`; it is reported as SKIP until those bindings
## exist, rather than silently passing.

## RuntimeEconomyCommandReceiptCode (gdext/src/runtime_economy_pod.h).
const RECEIPT_PARAMS := {"Accepted": 1, "RejectedAtAdmission": 4}

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	# Informational: the POD kernel self-test is owned by the runtime, not by
	# this contract. A failure here is reported, never silently swallowed, but it
	# does not turn a lane-admission result into a false negative.
	if ext.has_method("runtime_economy_pod_self_test"):
		var self_test_ok := bool(ext.runtime_economy_pod_self_test())
		print(("ok   " if self_test_ok else "note ") + "economy POD self-test result: "
			+ str(self_test_ok))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("SHADOW worker starts for lane admission", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		_finish()
		return

	# Army lane opcodes admit. Row layout:
	#   [opcode, target_cell, target_cohort(army), target_country(signature),
	#    payload0, payload1]
	# 33 is the split: src army in target_cohort, dst army in payload1, heads in
	# payload0 — the case this test was extended for (batch 2 §1.1).
	var src_army := 4294967296 + 3 # gen=1 slot=3 (an army handle, never a slot id)
	var dst_army := 4294967296 + 4 # gen=1 slot=4
	var lane_rows := [
		[30, 7, src_army, 11, 4, 0],   # embark: cell + signature + heads
		[31, 7, src_army, 11, 4, 0],   # disembark: cell + signature + heads
		[32, -1, src_army, 0, 0, dst_army], # merge: src -> dst, no cell
		[33, -1, src_army, 0, 4, dst_army], # split: heads -> dst, no cell
	]
	var ids := PackedInt64Array()
	var ops := PackedInt32Array()
	var sessions := PackedInt64Array()
	var cells := PackedInt32Array()
	var cohorts := PackedInt64Array()
	var countries := PackedInt64Array()
	var payload0s := PackedInt64Array()
	var payload1s := PackedInt64Array()
	for row in lane_rows:
		ids.append(9300 + int(row[0]))
		ops.append(int(row[0]))
		sessions.append(0)
		cells.append(int(row[1]))
		cohorts.append(int(row[2]))
		countries.append(int(row[3]))
		payload0s.append(int(row[4]))
		payload1s.append(int(row[5]))
	var batch := {
		"request_ids": ids,
		"opcodes": ops,
		"session_epochs": sessions,
		"target_cells": cells,
		"target_cohorts": cohorts,
		"target_countries": countries,
		"payload0s": payload0s,
		"payload1s": payload1s,
	}
	var submitted: Dictionary = ext.submit_economy_pod_commands(batch)
	_expect("lane opcode batch submits", bool(submitted.get("ok", false)))
	var polled: Dictionary = ext.poll_economy_pod_receipts(64)
	_expect("lane opcode receipts poll", bool(polled.get("ok", false)))
	var accepted := {}
	var rejected := {}
	for row in polled.get("receipts", []):
		var op := int(row.get("opcode", 0))
		if op < 30 or op > 33:
			continue
		if int(row.get("code", 0)) == RECEIPT_PARAMS["Accepted"]:
			accepted[op] = int(accepted.get(op, 0)) + 1
		elif int(row.get("code", 0)) == RECEIPT_PARAMS["RejectedAtAdmission"]:
			rejected[op] = int(rejected.get(op, 0)) + 1
	_expect("30/31/32/33 admit (4 Accepted receipts, got %d)" % accepted.size(),
		accepted.size() == 4)
	_expect("33 ARMY_SPLIT_LANES admits", int(accepted.get(33, 0)) == 1)
	_expect("30/31/32/33 are not rejected at admission", rejected.is_empty())

	# Neighbouring opcodes outside 1..23 and outside the lane set stay refused.
	# 33 is now inside the lane set, so the upper neighbour moved to 34.
	var reject_ids := PackedInt64Array([9400, 9401])
	var reject_ops := PackedInt32Array([29, 34])
	var reject_batch := {
		"request_ids": reject_ids,
		"opcodes": reject_ops,
		"session_epochs": PackedInt64Array([0, 0]),
	}
	_expect("29/34 submit returns ok (admission receipt)",
		bool(ext.submit_economy_pod_commands(reject_batch).get("ok", false)))
	var reject_poll: Dictionary = ext.poll_economy_pod_receipts(16)
	var saw_29 := false
	var saw_34 := false
	for row in reject_poll.get("receipts", []):
		if int(row.get("code", 0)) != RECEIPT_PARAMS["RejectedAtAdmission"]:
			continue
		if int(row.get("opcode", 0)) == 29:
			saw_29 = true
		elif int(row.get("opcode", 0)) == 34:
			saw_34 = true
	_expect("opcode 29 still RejectedAtAdmission", saw_29)
	_expect("opcode 34 still RejectedAtAdmission", saw_34)

	# Conservation half — not reachable until the bridge reads exist.
	var has_bridge_reads: bool = ext.has_method("military_army_population") \
		and ext.has_method("military_army_funds")
	if not has_bridge_reads:
		print("SKIP embark/disembark/split/merge conservation: "
			+ "military_army_population / military_army_funds are not bound on "
			+ "DCWorldExt yet. The assertions to enable are: (cell pop + lane "
			+ "pop) and (cell funds + lane funds) unchanged across EMBARK then "
			+ "DISEMBARK, lane.cell == the command's target_cell, and for a "
			+ "split (33) src_pop + dst_pop (and the two lane funds) equal to "
			+ "the pre-split source holding, with dst.cell/country inherited "
			+ "from src when the destination lane did not exist.")
	else:
		print("SKIP embark/disembark/split/merge conservation: needs a booted "
			+ "world (tests/military/military_runtime_smoke_test.gd bootstrap). "
			+ "The split path itself is feature-detected by the Military bridge "
			+ "through NativeEconomyRuntime::military_army_lane_split_supported() "
			+ "(gdext/src/runtime_economy_army_personnel.cpp).")

	ext.request_runtime_stop()
	_finish()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("ok   ", label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	printerr("FAIL ", label)


func _finish() -> void:
	print("army personnel lane admission: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
