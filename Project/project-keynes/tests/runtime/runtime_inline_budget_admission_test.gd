extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

class InlineHost extends WorldRuntimeHost:
	func _native_daily_inline_requested() -> bool:
		return true


func _run() -> void:
	OS.set_environment("PK_INLINE_DAY_BUDGET_MS", "1")
	await _run_world(false)
	_finish()


func _create_host() -> WorldRuntimeHost:
	return InlineHost.new()


func _sample_world(host: WorldRuntimeHost, _clock: WorldClock, _stall: bool) -> Dictionary:
	var ext: Object = host.get_generator().get_data_core_world_ext()
	_expect("formal session uses the inline executor", host._native_environment_active and host._native_daily_inline_active)
	var attempt: Dictionary = ext.run_native_daily_inline_day()
	var unfinished: bool = attempt.get("reason") == "inline_daily_day_budget_exceeded" \
		and bool(attempt.get("budget_exceeded", false)) and ext.runtime_committed_day() == 0
	_expect("the budget exit leaves day one uncommitted", unfinished)
	if unfinished:
		print("INLINE_BUDGET_ADMISSION submitting request 501 at committed day 0")
		var receipt: Dictionary = ext.submit_runtime_command({"request_id": 501,
			"producer_id": 2, "requested_day": 1, "domain": 1, "opcode": 1})
		_expect("the same thread receives the date of the retriable day", bool(receipt.get("pending", false))
			and receipt.get("effective_day") == 1 and ext.runtime_committed_day() == 0)
		print("INLINE_BUDGET_ADMISSION ", JSON.stringify(receipt))
	return {}
