extends "res://tests/economy/economy_rolling_runtime_test.gd"

# The one technology the fixture leaves unresearched, so research is queued
# and the fiscal research floor applies.
const RESEARCH_TECH := "tech.wild_maize_collection"
const RESEARCH_SIGNAL := "bio.maize"


func _init() -> void:
	_run()
	print("=== fiscal reservation cash cap %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10
	# Research cash is a share of the treasury (whole treasury x research
	# share); 10000 bp asks for more than one epoch of cash can cover.
	for research_share_bp in [0, 1000, 10000]:
		_check_cash_cap(compiled, catalog, profile, research_share_bp)
	_check_cash_cap(compiled, catalog, profile, 1000, true)


func _check_cash_cap(compiled: Dictionary, catalog: Dictionary,
		profile: Dictionary, research_share_bp: int, country_worker: bool = false) -> void:
	var runtime := _new_runtime(compiled, catalog, profile, 104172, false,
		PackedStringArray([RESEARCH_TECH]))
	if runtime == null:
		return
	var handle := int(runtime.get_country_cell_summary(0).country_handle)
	var population: Dictionary = runtime.get_population_cell_snapshot(0)
	var handles: PackedInt64Array = population.get("handles", PackedInt64Array())
	_expect("cash cap fixture has a treasury donor", not handles.is_empty())
	if handles.is_empty():
		return
	_expect("cash cap fixture funds treasury", _transfer_from_cohort(
		runtime, handles[0], 100001, 0, 1))
	_validate_day(runtime, 0)
	var opening_cash := int(runtime.get_country_treasury_snapshot(handle).cash)
	_expect("cash cap fixture has exact treasury balance", opening_cash == 100001)
	_expect("cash cap research policy commits", _queue_research(
		runtime, compiled, handle, research_share_bp))
	var research_daily := opening_cash * research_share_bp / 10000
	# The due cells request much more than the treasury can reserve. The
	# original denominator allocated that entire request from capped escrow.
	_expect("oversubscribed income subsidy commits", _set_tax_value(
		runtime, handle, 0, -1, -1000000, 1, 1, 3))
	if country_worker:
		_expect("cash cap Country worker starts", _start_country_worker(runtime))
	var saw_pending := false
	var completed := false
	for step in range(1024):
		var slice: Dictionary
		if country_worker:
			runtime.advance_runtime_pulse(1, 0.0, 1.0, 50)
			slice = runtime.get_economy_report()
			var protocol: Dictionary = runtime.get_country_economy_asset_protocol_status()
			saw_pending = saw_pending or int(protocol.get("pending_requests", 0)) > 0
		else:
			slice = runtime.run_economy_slice({
				"day_index": 1, "tick_index": 1000 + step, "slice_budget_ms": 8.0})
		if bool(slice.get("done", false)) or (country_worker and
				int(slice.get("fiscal_reservation_continuation_phase", 0)) == 2 and
				not bool(slice.get("fiscal_reservation_continuation_active", true))):
			completed = true
			break
		if bool(slice.get("fatal", false)):
			break
		if country_worker:
			runtime.set_runtime_clock(false, 1000.0)
			OS.delay_msec(3)
			runtime.set_runtime_clock(true, 1000.0)
	_expect("cash cap reservation/epoch completes", completed)
	if country_worker:
		_expect("cash cap reservation retries a Country peer request", saw_pending)
		var reserved_report: Dictionary = runtime.get_economy_report()
		var actual := int(reserved_report.get("fiscal_reservation_last_reserved", -1))
		var expected := maxi(0, opening_cash - research_daily * int(
			reserved_report.get("epoch_days", 1)))
		_expect("cash cap peer completes the admitted capped request",
			not bool(reserved_report.get("fatal", true)) and actual == expected and
			int(reserved_report.get("fiscal_reservation_last_requested", -1)) == expected)
		runtime.request_runtime_stop()
		for attempt in range(100):
			if String(runtime.get_runtime_thread_report().get("state", "")) in ["STOPPED", "FAULTED"]:
				break
			OS.delay_msec(2)
		runtime = null
		return
	var report: Dictionary = runtime.get_economy_report()
	var fiscal: Dictionary = runtime.get_country_fiscal_snapshot(handle)
	var reserved := _sum_i64(fiscal.get("subsidy_reserved", PackedInt64Array()))
	var paid := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var actual_reserved := int(report.get("fiscal_reservation_last_reserved", -1))
	var expected_reserved := maxi(0, opening_cash - research_daily * int(
		report.get("epoch_days", 1)))
	_expect("research_share=%d actual escrow obeys cash floor" % research_share_bp,
		actual_reserved == expected_reserved)
	_expect("research_share=%d lane budgets equal actual escrow" % research_share_bp,
		reserved == actual_reserved)
	_expect("research_share=%d subsidy payout stays inside escrow" % research_share_bp,
		paid >= 0 and paid <= actual_reserved)
	_expect("research_share=%d settlement completes without fatal" % research_share_bp,
		not bool(report.get("fatal", true)) and int(report.get("newest_state_day", -1)) == 1)
	_expect("research_share=%d treasury retains research cash" % research_share_bp,
		int(runtime.get_country_treasury_snapshot(handle).cash) >=
			mini(opening_cash, research_daily))
	_expect("research_share=%d all conservation errors are zero" % research_share_bp,
		int(report.get("population_error", -1)) == 0 and
		int(report.get("money_error", -1)) == 0 and
		int(report.get("goods_error", -1)) == 0)
	runtime = null


func _start_country_worker(runtime: Object) -> bool:
	if not bool(runtime.capture_country_pod_catalog().get("ok", false)) or \
			not bool(runtime.capture_country_runtime_snapshot().get("ok", false)):
		return false
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(1)
	var offsets := PackedInt32Array()
	offsets.resize(CELL_COUNT + 1)
	offsets.fill(0)
	if not bool(runtime.capture_runtime_inputs({
		"generation": 1, "day": 1, "terrain": terrain,
		"neighbor_offsets": offsets, "neighbor_indices": PackedInt32Array(),
	}).get("ok", false)):
		return false
	runtime.configure_runtime_graph({"enabled": true, "day": 1})
	if not bool(runtime.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE", "graph_coverage_complete": true,
		"authoritative_domain_mask": 0x004, "day": 1,
		"speed_days_per_second": 1000.0, "paused": false,
	}).get("ok", false)):
		return false
	for attempt in range(100):
		if (int(runtime.get_runtime_thread_report().get(
				"authoritative_domain_mask", 0)) & 0x004) != 0:
			runtime.set_runtime_clock(true, 1000.0)
			return true
		OS.delay_msec(2)
	return false


func _queue_research(runtime: Object, compiled: Dictionary, handle: int,
		research_share_bp: int) -> bool:
	var signal_index := (compiled.get("research_signal_ids", PackedStringArray()) as
		PackedStringArray).find(RESEARCH_SIGNAL)
	var technology := (compiled.technology_ids as PackedStringArray).find(RESEARCH_TECH)
	if signal_index < 0 or technology < 0:
		return false
	# Opcodes 14 / 6 / 9: discover the signal, queue the technology, turn
	# auto purchase on. The budget itself comes from the procurement policy.
	if not _submit_country(runtime, 14, 1, 2, signal_index, 0, 1) or \
			not _submit_country(runtime, 6, 1, 3, technology, -1, 0) or \
			not _submit_country(runtime, 9, 1, 4, 1, -1, 0) or \
			not bool(runtime.run_country_slice({"day_index": 1}).get("ok", false)):
		return false
	var research: Dictionary = runtime.get_country_research_snapshot(handle)
	var queued := (research.get("technology_states", PackedInt32Array()) as
		PackedInt32Array)[technology] == 3
	return queued and bool(runtime.set_country_procurement_policy(
		handle, true, 10000, research_share_bp, 1, 5).get("ok", false))


func _submit_country(runtime: Object, opcode: int, day: int, sequence: int,
		aux: int, cell: int, value: int) -> bool:
	return bool(runtime.submit_country_commands({
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([int(runtime.get_country_cell_summary(0).country_handle)]),
		"cell_indices": PackedInt32Array([cell]),
		"aux_i32": PackedInt32Array([aux]),
		"domain_i32": PackedInt32Array([0 if opcode == 6 else -1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([value]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	}).get("ok", false))
