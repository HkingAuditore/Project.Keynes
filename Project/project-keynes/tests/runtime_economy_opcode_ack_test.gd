extends SceneTree

## Phase 4 opcode admission + receipt ACK scaffold.
## Commit/Committed/duplicate terminal coverage lives in
## RuntimeEconomyPodAuthority::self_test (via runtime_economy_pod_self_test).

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
	_expect("Economy POD self-test covers opcode admission",
		ext.has_method("runtime_economy_pod_self_test")
		and bool(ext.runtime_economy_pod_self_test()))
	_expect("POD submit/poll Dictionary API exists",
		ext.has_method("submit_economy_pod_commands")
		and ext.has_method("poll_economy_pod_receipts"))

	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("SHADOW worker starts for POD command admission",
		bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		_finish()
		return

	# Opcode 0 must admit as RejectedAtAdmission (not hard-fail the batch API).
	var reject_batch := {
		"request_ids": PackedInt64Array([9001]),
		"opcodes": PackedInt32Array([0]),
		"session_epochs": PackedInt64Array([1]),
	}
	var reject_submit: Dictionary = ext.submit_economy_pod_commands(reject_batch)
	_expect("opcode 0 submit returns ok (admission receipt)",
		bool(reject_submit.get("ok", false)))
	var reject_poll: Dictionary = ext.poll_economy_pod_receipts(8)
	_expect("opcode 0 poll ok", bool(reject_poll.get("ok", false)))
	var reject_rows: Array = reject_poll.get("receipts", [])
	var saw_reject := false
	for row in reject_rows:
		if int(row.get("request_id", 0)) == 9001 and int(row.get("code", 0)) == 4:
			saw_reject = true
			break
	_expect("opcode 0 yields RejectedAtAdmission (code=4)", saw_reject)

	# Opcodes 1..23 admit (batch). Generation 0 is wildcard.
	var ids := PackedInt64Array()
	var ops := PackedInt32Array()
	var sessions := PackedInt64Array()
	var payloads := PackedInt64Array()
	for opcode in range(1, 24):
		ids.append(9100 + opcode)
		ops.append(opcode)
		sessions.append(0)
		payloads.append(1 if opcode == 20 else 0)
	var admit_batch := {
		"request_ids": ids,
		"opcodes": ops,
		"session_epochs": sessions,
		"payload0s": payloads,
	}
	var admit_submit: Dictionary = ext.submit_economy_pod_commands(admit_batch)
	_expect("opcodes 1..23 admit batch ok", bool(admit_submit.get("ok", false)))
	var admit_poll: Dictionary = ext.poll_economy_pod_receipts(64)
	_expect("opcodes 1..23 poll ok", bool(admit_poll.get("ok", false)))
	var admit_rows: Array = admit_poll.get("receipts", [])
	var accepted_count := 0
	for row in admit_rows:
		if int(row.get("code", 0)) == 1:
			accepted_count += 1
	_expect("opcodes 1..23 produce Accepted receipts", accepted_count >= 23)

	# BUILD_CANAL without token: admit, then RejectedAtExecution after day commit
	# path is covered by C++ self_test; surface check: canal opcode 20 admits.
	var canal_batch := {
		"request_ids": PackedInt64Array([9200]),
		"opcodes": PackedInt32Array([20]),
		"session_epochs": PackedInt64Array([0]),
		"payload0s": PackedInt64Array([0]),
	}
	var canal_submit: Dictionary = ext.submit_economy_pod_commands(canal_batch)
	_expect("canal missing-token still admits", bool(canal_submit.get("ok", false)))
	var canal_poll: Dictionary = ext.poll_economy_pod_receipts(8)
	_expect("canal missing-token poll ok", bool(canal_poll.get("ok", false)))
	var canal_rows: Array = canal_poll.get("receipts", [])
	var saw_canal_accept := false
	for row in canal_rows:
		if int(row.get("request_id", 0)) == 9200 and int(row.get("code", 0)) == 1:
			saw_canal_accept = true
			break
	_expect("canal missing-token yields Accepted until commit", saw_canal_accept)

	ext.request_runtime_stop()
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_opcode_ack_test checks=%s failures=%s" % [
		_checks, _failures])
	quit(1 if _failures > 0 else 0)
