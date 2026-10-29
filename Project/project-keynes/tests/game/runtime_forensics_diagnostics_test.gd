extends SceneTree

const RuntimeForensics = preload("res://scripts/game/runtime_forensics.gd")

class StubGenerator extends RefCounted:
	var economy_report: Dictionary = {}

	func get_economy_report() -> Dictionary:
		return economy_report

	func get_country_report() -> Dictionary:
		return {}

	func get_runtime_thread_report() -> Dictionary:
		return {}


class StubClock extends RefCounted:
	var paused := true
	var speed_multiplier := 0.0

	func day_index() -> int:
		return 42


var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var stage_rows := [{
		"day": 42,
		"epoch_id": 41,
		"where": "slice",
		"stage": "fiscal_settlement",
		"executed_stage": "fiscal_settlement",
		"substage": "verify",
		"diff": 213072,
		"delta": 213072,
		"money_now": 3161473879,
		"money_expected": 3161260807,
		"cohort_funds": 2374033682,
		"country_cash": 787440197,
		"escrow_cash": 0,
		"explicit_money_mint": 666965,
		"explicit_money_burn": 0,
	}]
	var account_rows := [{
		"slot": 5,
		"cell": 422,
		"profession": "unemployed",
		"opening_funds": 24650346,
		"closing_funds": 56600815,
		"net_change": 31950469,
	}]
	var generator := StubGenerator.new()
	generator.economy_report = {
		"fatal": true,
		"fatal_reason": "money_conservation_failed",
		"stage": "fatal",
		"executed_stage": "fiscal_settlement",
		"executed_substage": "verify",
		"epoch_id": 41,
		"current_day": 42,
		"fatal_context": {"reason": "money_conservation_failed", "day": 42},
		"money_error": 213072,
		"money_open": 3160593842,
		"money_close": 3161473879,
		"money_expected": 3161260807,
		"explicit_money_mint": 666965,
		"explicit_money_burn": 0,
		"money_stage_diagnostics": stage_rows,
		"money_audit_candidate_accounts": account_rows,
	}
	var payload := RuntimeForensics.capture(
		"money_conservation_failed", generator, StubClock.new())
	var conservation: Dictionary = payload.get("economy_conservation", {})
	_expect(conservation.get("money_stage_diagnostics", []) == stage_rows,
		"fatal capture must preserve stage diagnostics")
	_expect(conservation.get("money_audit_candidate_accounts", []) == account_rows,
		"fatal capture must preserve candidate accounts")
	var trace_lines := RuntimeForensics._build_economy_trace_lines(
		payload, "runtime_worker_fault")
	_expect(_contains(trace_lines, "money-ledger") and _contains(trace_lines, "213072"),
		"trace output must include the full money ledger error")
	_expect(_contains(trace_lines, "money-stage") and _contains(trace_lines, "fiscal_settlement"),
		"trace output must include the stage where the difference was observed")
	_expect(_contains(trace_lines, "money-first-observed") and _contains(trace_lines, "diff=213072"),
		"trace output must identify the first observed nonzero stage difference")
	_expect(_contains(trace_lines, "money-candidate") and _contains(trace_lines, "422"),
		"trace output must include candidate account details")
	_expect(RuntimeForensics._should_print_economy_trace("economy_fatal"),
		"economy fatal must emit an economy trace")
	_expect(RuntimeForensics._should_print_economy_trace("runtime_worker_fault"),
		"worker fault must emit an economy trace even when economy is fatal")
	_expect(RuntimeForensics._should_print_economy_trace("stall"),
		"stall capture must emit an economy trace")
	_expect(not RuntimeForensics._should_print_economy_trace("save_replay"),
		"ordinary save replay capture must not emit a pause trace")
	print("runtime_forensics_diagnostics_test: %d checks, %d failures" % [_checks, _failures])


func _contains(lines: PackedStringArray, fragment: String) -> bool:
	for line in lines:
		if line.contains(fragment):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	push_error("runtime_forensics_diagnostics_test: " + message)
